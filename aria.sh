#!/bin/sh
# ARIA - Gerenciador de Pacotes minimalista (estilo KISS)
# Recursos: build/inst/remove/list/sync/revdep/rebuild-world/upgrade/checksum/mkchecksum
# Deps externas: sh, tar, gzip/xz/zstd, curl, sha256sum, git, awk, sed, find, sort, ldd, file
# Licença: permissiva

set -e
[ "${ARIA_DEBUG:-0}" = "1" ] && set -x

# ===== Variáveis (sobrepõe via ~/.profile) =====
ARIA_ROOT="${ARIA_ROOT:-/}"
ARIA_PATH="${ARIA_PATH:-/var/db/aria/repo/core:/var/db/aria/repo/extra}"
ARIA_INSTALLED="${ARIA_INSTALLED:-/var/db/aria/installed}"
ARIA_CACHE="${ARIA_CACHE:-/var/cache/aria}"
ARIA_SRC="${ARIA_SRC:-$ARIA_CACHE/sources}"
ARIA_BUILD="${ARIA_BUILD:-$ARIA_CACHE/build}"
ARIA_COMPRESS="${ARIA_COMPRESS:-gz}"     # gz | xz | zst
ARIA_COLOR="${ARIA_COLOR:-1}"
ARIA_PROMPT="${ARIA_PROMPT:-1}"
ARIA_WITH_OPT="${ARIA_WITH_OPT:-0}"      # 1 inclui deps marcadas com '?'
ARIA_SU="${ARIA_SU:-sudo}"

# ===== Utilitários =====
die(){ echo "aria: $*" >&2; exit 1; }
yesno(){ [ "$ARIA_PROMPT" = "0" ] && return 0; printf "%s [y/N] " "$1"; read -r a; [ "$a" = "y" ] || [ "$a" = "Y" ]; }
msg(){ if [ "$ARIA_COLOR" = "1" ]; then printf "\033[1;32m%s\033[0m\n" "$*"; else echo "$*"; fi; }
ensure_dirs(){ mkdir -p "$ARIA_SRC" "$ARIA_BUILD" "$ARIA_INSTALLED"; }
base(){ basename -- "$1"; }

compress_write(){ # stdin -> $1 conforme $ARIA_COMPRESS
    out="$1"
    case "$ARIA_COMPRESS" in
        gz)  gzip  -9  > "$out" ;;
        xz)  xz    -9e > "$out" ;;
        zst) zstd  -19 -q -o "$out" ;;
        *) die "compressor desconhecido: $ARIA_COMPRESS" ;;
    esac
}

decompress_tar(){ # extrai $1 no CWD
    f="$1"
    case "$f" in
        *.tar.gz|*.tgz)   tar xzf "$f" ;;
        *.tar.xz)         tar xJf "$f" ;;
        *.tar.zst|*.tzst) zstd -dc "$f" | tar xf - ;;
        *.tar)            tar xf "$f" ;;
        *) die "não sei descompactar: $f" ;;
    esac
}

# ===== Localização de pacotes e leitura de metadados =====
aria_find_pkg(){ # imprime path do pacote
    name="$1"
    IFS=:; for repo in $ARIA_PATH; do IFS=' '
        [ -d "$repo/$name" ] && { printf "%s\n" "$repo/$name"; return 0; }
    done
    return 1
}

# Lê version, sources, checksums, depends (com suporte a make/? e filtra comentários)
aria_read_meta(){ # $1 path do pacote -> 4 linhas: ver \n srcs \n chks \n deps_runtime
    p="$1"
    [ -f "$p/version" ]   || die "sem version em $p"
    ver=$(sed -n '1p' "$p/version")

    srcs=""
    [ -f "$p/sources" ]   && srcs=$(sed 's/#.*$//' "$p/sources" | sed '/^[[:space:]]*$/d')

    chks=""
    [ -f "$p/checksums" ] && chks=$(sed 's/#.*$//' "$p/checksums" | sed '/^[[:space:]]*$/d')

    # depends pode conter:
    #   foo           -> runtime
    #   bar make      -> build-only
    #   baz ?         -> opcional
    # saída desta função retorna **apenas runtime** (a menos de ARIA_WITH_OPT=1)
    deps_runtime=""
    if [ -f "$p/depends" ]; then
        while IFS= read -r line; do
            set -- $line
            dep="$1"; tag="$2"
            [ -z "$dep" ] && continue
            [ "$tag" = "make" ] && continue
            if printf "%s" "$line" | grep -q '\?$'; then
                [ "$ARIA_WITH_OPT" = "1" ] || continue
                dep=$(printf "%s" "$dep" | sed 's/\?$//')
            fi
            deps_runtime="$deps_runtime
$dep"
        done <<EOF
$(sed 's/#.*$//' "$p/depends" 2>/dev/null | sed '/^[[:space:]]*$/d')
EOF
    fi

    printf "%s\n%s\n%s\n%s\n" "$ver" "$srcs" "$chks" "$(printf "%s" "$deps_runtime" | sed '/^[[:space:]]*$/d')"
}

# Lê dependências de build (linhas com 'make')
aria_read_builddeps(){ # $1 path -> lista (uma por linha)
    p="$1"
    [ -f "$p/depends" ] || { :; return 0; }
    sed 's/#.*$//' "$p/depends" | sed '/^[[:space:]]*$/d' | awk '
    {
        dep=$1; tag=$2;
        if (tag=="make") print dep;
    }'
}

# Lê provides do pacote (opcional): linhas "nomevirtual [versao]"
aria_read_provides(){ # $1 path -> lista (uma por linha, só nomevirtual)
    p="$1"
    [ -f "$p/provides" ] || { :; return 0; }
    sed 's/#.*$//' "$p/provides" | sed '/^[[:space:]]*$/d' | awk '{print $1}'
}

# Índice de provides -> pacote
# gera cache leve em memória: PROV_map="virtA=pkgA\nvirtB=pkgB"
PROV_map=""
build_provides_index(){
    PROV_map=""
    IFS=:; for repo in $ARIA_PATH; do IFS=' '
        [ -d "$repo" ] || continue
        for p in "$repo"/*; do
            [ -d "$p" ] || continue
            for v in $(aria_read_provides "$p"); do
                PROV_map="${PROV_map}
${v}=$(base "$p")"
            done
        done
    done
}

# Resolve nome -> pacote real (considera provides)
resolve_pkg_name(){ # ecoa nome real do pacote
    n="$1"
    if aria_find_pkg "$n" >/dev/null 2>&1; then
        printf "%s\n" "$n"; return 0
    fi
    # tenta provides
    printf "%s" "$PROV_map" | sed '/^[[:space:]]*$/d' | while IFS='=' read -r virt real; do
        [ "$virt" = "$n" ] && { printf "%s\n" "$real"; return 0; }
    done
    return 1
}

# ===== Download + checksum =====
aria_fetch_sources(){ # $1 pacote path, $2 srcs, $3 checksums
    p="$1"; srcs="$2"; chks="$3"
    ensure_dirs
    i=1
    echo "$srcs" | while IFS= read -r url; do
        [ -n "$url" ] || continue
        case "$url" in
            http://*|https://*)
                fn="$ARIA_SRC/$(base "$url")"
                if [ ! -f "$fn" ] || [ "${ARIA_FORCE:-0}" = "1" ]; then
                    msg "↓ baixando $(base "$url")"
                    (cd "$ARIA_SRC" && curl -L -O "$url")
                fi
                ;;
            file://*)
                fp="${url#file://}"
                cp -f "$fp" "$ARIA_SRC/"
                fn="$ARIA_SRC/$(base "$fp")"
                ;;
            /*)
                cp -f "$url" "$ARIA_SRC/"
                fn="$ARIA_SRC/$(base "$url")"
                ;;
            *)
                die "fonte não suportada: $url"
                ;;
        esac
        sum=$(printf "%s\n" "$chks" | sed -n "${i}p")
        [ -n "$sum" ] || die "faltou checksum #$i para $(base "$url")"
        ( cd "$ARIA_SRC" && printf "%s  %s\n" "$sum" "$(base "$url")" | sha256sum -c - ) || die "checksum falhou: $(base "$url")"
        i=$((i+1))
    done
}
# ===== Hooks =====
# Hooks globais: /var/db/aria/hooks/{pre-build,post-build,pre-install,post-install,pre-remove,post-remove}
# Hooks por pacote: <repo>/<pkg>/hooks/{pre-build,post-build,...}
run_hooks(){ # $1 stage, $2 pkg, $3 ver, $4 fakeroot, $5 pkgpath, $6 workdir
    stage="$1"; pkg="$2"; ver="$3"; fakeroot="$4"; pkgpath="$5"; workdir="$6"
    export ARIA_STAGE="$stage" ARIA_PKG="$pkg" ARIA_VER="$ver" ARIA_FAKE_ROOT="$fakeroot" ARIA_PATH_PKG="$pkgpath" ARIA_WORKDIR="$workdir" ARIA_ROOT

    # hooks globais
    hg="/var/db/aria/hooks/$stage"
    if [ -d "/var/db/aria/hooks" ]; then
        for h in /var/db/aria/hooks/*; do :; done # garantir glob
        for h in $(ls -1 /var/db/aria/hooks 2>/dev/null | sort); do
            [ "$h" = "$stage" ] || continue
            for s in /var/db/aria/hooks/$h/*; do
                [ -x "$s" ] || continue
                "$s" || [ "${ARIA_FORCE:-0}" = "1" ] || die "hook falhou: $s"
            done
        done
    fi
    # hooks por pacote
    if [ -d "$pkgpath/hooks/$stage" ]; then
        for s in "$pkgpath/hooks/$stage"/*; do
            [ -x "$s" ] || continue
            "$s" || [ "${ARIA_FORCE:-0}" = "1" ] || die "hook falhou: $s"
        done
    fi
}

# ===== Grafo e ordenação de dependências (evoluído) =====
# Suporta: runtime deps, build deps (make), opcionais (?), provides virtuais, detecção de ciclos e faltantes
_seen=""; _temp=""; _order=""
_missing=""; _reqby=""

mark_seen(){ printf "%s\n" "$_seen" | grep -qx "$1"; }
mark_temp(){ printf "%s\n" "$_temp" | grep -qx "$1"; }

push_seen(){ _seen="${_seen}
$1"; }
push_temp(){ _temp="${_temp}
$1"; }
pop_temp(){ _temp=$(printf "%s" "$_temp" | sed "\|^$1\$|d"); }
push_order(){ _order="${_order}
$1"; }

note_missing(){ # $1 dep, $2 requerente
    _missing="${_missing}
$1"
    _reqby="${_reqby}
$1 <- $2"
}

# retorna lista de deps de build + runtime para ordenação completa
collect_deps_all(){ # $1 packpath
    p="$1"
    run=""
    set -- $(aria_read_meta "$p"); ver="$1"; srcs="$2"; chks="$3"; run="$4"
    make=$(aria_read_builddeps "$p")
    printf "%s\n%s\n" "$run" "$make" | sed '/^[[:space:]]*$/d' | awk '!seen[$0]++'
}

dep_resolve_dfs(){
    # arg: nome do pacote REQUERENTE (já resolvido) e path
    pkg="$1"; ppath="$2"

    mark_seen "$pkg" && return 0
    if mark_temp "$pkg"; then
        die "ciclo de dependências detectado envolvendo: $pkg"
    fi
    push_temp "$pkg"

    # coletar deps (runtime + make), resolvendo provides
    for d in $(collect_deps_all "$ppath"); do
        real="$(resolve_pkg_name "$d" || true)"
        if [ -z "$real" ]; then
            note_missing "$d" "$pkg"
            continue
        fi
        dpath=$(aria_find_pkg "$real") || { note_missing "$d" "$pkg"; continue; }
        dep_resolve_dfs "$real" "$dpath"
    done

    pop_temp "$pkg"; push_seen "$pkg"; push_order "$pkg"
}

dep_order(){ # entrada: lista de pkgs (nomes reais)
    _seen=""; _temp=""; _order=""; _missing=""; _reqby=""
    build_provides_index
    for p in "$@"; do
        path=$(aria_find_pkg "$p") || { note_missing "$p" "root"; continue; }
        dep_resolve_dfs "$p" "$path"
    done
    # reporta faltantes se houver (e não estiver em --force)
    miss=$(printf "%s" "$_missing" | sed '/^[[:space:]]*$/d' | sort -u)
    if [ -n "$miss" ] && [ "${ARIA_FORCE:-0}" != "1" ]; then
        echo "Dependências não resolvidas:" >&2
        printf "%s\n" "$_reqby" | sed '/^[[:space:]]*$/d' | sort -u >&2
        exit 1
    fi
    printf "%s" "$_order" | sed '/^[[:space:]]*$/d' | awk '!seen[$0]++'
}

# ===== BUILD (estilo KISS, com hooks e deps de build) =====
aria_build(){
    pkg="$1"
    path=$(aria_find_pkg "$pkg") || die "pacote não encontrado: $pkg"
    set -- $(aria_read_meta "$path")
    ver="$1"; srcs="$2"; chks="$3"; deps_runtime="$4"

    # 1) deps: calcular ordem incluindo deps de build e runtime
    order=$(dep_order "$pkg") # inclui o próprio pkg no fim; garantimos dependências antes
    # construir tudo da ordem exceto o próprio, se desejar garantir toolchain
    for d in $order; do
        [ "$d" = "$pkg" ] && continue
        # se já instalado, ok; senão, tenta build + install
        if [ ! -d "$ARIA_INSTALLED/$d" ]; then
            msg "↳ build (dep) $d"
            aria_build "$d"
            dver=$(sed -n '1p' "$(aria_find_pkg "$d")/version")
            aria_install "${d}-${dver}.tar.${ARIA_COMPRESS}"
        fi
    done

    ensure_dirs
    [ -n "$srcs" ] && aria_fetch_sources "$path" "$srcs" "$chks"

    work="$ARIA_BUILD/${pkg}-${ver}"
    fakeroot="$ARIA_BUILD/${pkg}-pkg"
    rm -rf "$work" "$fakeroot"
    mkdir -p "$work" "$fakeroot"

    # fontes (todas) → work
    cd "$work"
    echo "$srcs" | while IFS= read -r url; do
        [ -n "$url" ] || continue
        fn="$ARIA_SRC/$(base "${url#file://}")"
        [ -f "$fn" ] || fn="$ARIA_SRC/$(base "$url")"
        [ -f "$fn" ] && decompress_tar "$fn" || true
    done

    # HOOK pre-build
    run_hooks "pre-build" "$pkg" "$ver" "$fakeroot" "$path" "$work"

    # rodar build script com $1 = fake root
    [ -x "$path/build" ] || chmod +x "$path/build" 2>/dev/null || true
    msg "⚙️  build $pkg-$ver"
    ( cd "$work" && sh "$path/build" "$fakeroot" )

    # HOOK post-build
    run_hooks "post-build" "$pkg" "$ver" "$fakeroot" "$path" "$work"

    # manifesto
    ( cd "$fakeroot" && find . -type f | sed 's|^\./||' ) > "$ARIA_BUILD/${pkg}.manifest"

    # pacote binário
    out="${pkg}-${ver}.tar.${ARIA_COMPRESS}"
    ( cd "$fakeroot" && tar -c . ) | compress_write "$out"

    msg "✓ build pronto: $out"
}

# ===== INSTALL (com hooks) =====
aria_install(){
    arg="$1"
    ensure_dirs

    if [ -z "$arg" ]; then die "uso: aria install <pkg>|<pacote.tar.*>"; fi

    pkgfile=""; pkg=""; ver=""
    if [ -f "$arg" ]; then
        pkgfile="$arg"
        basefn=$(base "$pkgfile")
        pkg="${basefn%%-*}"
        ver_ext="${basefn#${pkg}-}"
        ver="${ver_ext%%.tar.*}"
    else
        pkg="$arg"
        path=$(aria_find_pkg "$pkg") || die "pacote não encontrado: $pkg"
        ver=$(sed -n '1p' "$path/version")
        pkgfile="${pkg}-${ver}.tar.${ARIA_COMPRESS}"
        [ -f "$pkgfile" ] || { aria_build "$pkg"; }
        [ -f "$pkgfile" ] || die "não achei $pkgfile para instalar"
    fi

    # HOOK pre-install
    path=$(aria_find_pkg "$pkg" || true)
    run_hooks "pre-install" "$pkg" "$ver" "" "$path" ""

    msg "⇣ instalando $pkg-$ver em $ARIA_ROOT"
    tmp="$ARIA_BUILD/.inst-$pkg"
    rm -rf "$tmp"; mkdir -p "$tmp"
    case "$pkgfile" in
        *.zst|*.tzst) zstd -dc "$pkgfile" | (cd "$tmp" && tar xpf -) ;;
        *.xz)         xz   -dc "$pkgfile" | (cd "$tmp" && tar xpf -) ;;
        *.tar.gz|*.tgz)    (cd "$tmp" && tar xpf "$pkgfile") ;;
        *.tar)             (cd "$tmp" && tar xpf "$pkgfile") ;;
        *)            gzip -dc "$pkgfile" | (cd "$tmp" && tar xpf -) || (cd "$tmp" && tar xpf "$pkgfile") ;;
    esac

    ( cd "$tmp" && tar -c . ) | ( cd "$ARIA_ROOT" && ${ARIA_SU} tar xpf - )

    # registrar
    inst="$ARIA_INSTALLED/$pkg"
    rm -rf "$inst"; mkdir -p "$inst"
    echo "$ver" > "$inst/version"

    # deps runtime do repo
    if path=$(aria_find_pkg "$pkg"); then
        if [ -f "$path/depends" ]; then
            # somente runtime (remove make; opcional só com ARIA_WITH_OPT=1)
            sed 's/#.*$//' "$path/depends" \
            | sed '/^[[:space:]]*$/d' \
            | awk -v with_opt="$ARIA_WITH_OPT" '
                {
                    d=$1; t=$2;
                    if (t=="make") next;
                    if ($0 ~ /\?$/ && with_opt!=1) next;
                    sub(/\?$/,"",d);
                    print d;
                }' > "$inst/depends"
        else : > "$inst/depends"; fi
    else : > "$inst/depends"; fi

    # manifest
    if [ -f "$ARIA_BUILD/${pkg}.manifest" ]; then
        cp "$ARIA_BUILD/${pkg}.manifest" "$inst/manifest"
    else
        ( cd "$tmp" && find . -type f | sed 's|^\./||' ) > "$inst/manifest"
    fi

    rm -rf "$tmp"

    # HOOK post-install
    path=$(aria_find_pkg "$pkg" || true)
    run_hooks "post-install" "$pkg" "$ver" "" "$path" ""

    msg "✓ instalado: $pkg-$ver"
}

# ===== REMOVE (limpo, com hooks) =====
aria_remove(){
    pkg="$1"
    inst="$ARIA_INSTALLED/$pkg"
    [ -d "$inst" ] || die "$pkg não está instalado"

    yesno "Remover $pkg?" || die "abortado"

    # HOOK pre-remove
    path=$(aria_find_pkg "$pkg" || true)
    ver=$(sed -n '1p' "$inst/version" 2>/dev/null || echo "")
    run_hooks "pre-remove" "$pkg" "$ver" "" "$path" ""

    if [ -f "$inst/manifest" ]; then
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            rm -f "$ARIA_ROOT/$f" 2>/dev/null || [ "${ARIA_FORCE:-0}" = "1" ] || die "falha removendo $f (use --force)"
        done < "$inst/manifest"
        # limpar diretórios vazios
        awk -F/ '{
            path="";
            for(i=1;i<NF;i++){ path=path $i "/"; print path }
        }' "$inst/manifest" | sort -r | uniq | while read -r d; do
            rmdir "$ARIA_ROOT/$d" 2>/dev/null || true
        done
    fi

    rm -rf "$inst"

    # HOOK post-remove
    run_hooks "post-remove" "$pkg" "$ver" "" "$path" ""

    msg "✗ removido: $pkg"
}
# ===== REVDEP (evoluído) =====
aria_revdep(){
    target="$1"
    [ -n "$target" ] || die "uso: aria revdep <pacote>"
    # dependenTES (runtime) de target
    dependents=""
    for p in "$ARIA_INSTALLED"/*; do
        [ -d "$p" ] || continue
        name=$(base "$p")
        [ -f "$p/depends" ] || continue
        if grep -qx "$target" "$p/depends" 2>/dev/null; then
            dependents="$dependents $name"
        fi
    done
    # checar ELF quebrado no alvo e dependentes (ldd not found)
    candidates="$target $dependents"
    broken=""
    for p in $candidates; do
        man="$ARIA_INSTALLED/$p/manifest"
        [ -f "$man" ] || continue
        while IFS= read -r f; do
            fp="$ARIA_ROOT/$f"
            [ -f "$fp" ] || continue
            if file "$fp" 2>/dev/null | grep -q "ELF"; then
                if ldd "$fp" 2>/dev/null | grep -q "not found"; then
                    broken="$broken $p"; break
                fi
            fi
        done < "$man"
    done
    tofix=$(printf "%s\n" $dependents $broken | sed '/^[[:space:]]*$/d' | sort -u)
    [ -z "$tofix" ] && { msg "revdep: nada a fazer"; return 0; }
    order=$(dep_order $tofix)
    for p in $order; do
        msg "↻ revdep rebuild: $p"
        aria_build "$p"
        ver=$(sed -n '1p' "$(aria_find_pkg "$p")/version")
        aria_install "${p}-${ver}.tar.${ARIA_COMPRESS}"
    done
}

# ===== rebuild de todo o sistema =====
aria_rebuild_world(){
    pkgs=$(ls -1 "$ARIA_INSTALLED" 2>/dev/null | sed '/^[[:space:]]*$/d')
    [ -n "$pkgs" ] || { msg "nada instalado"; return 0; }
    order=$(dep_order $pkgs)
    for p in $order; do
        msg "↻ rebuild: $p"
        aria_build "$p"
        ver=$(sed -n '1p' "$(aria_find_pkg "$p")/version")
        aria_install "${p}-${ver}.tar.${ARIA_COMPRESS}"
    done
}

# ===== upgrade (apenas major) =====
version_major(){ printf "%s" "$1" | awk -F. '{print $1}'; }
aria_upgrade(){
    pkg="$1"
    path=$(aria_find_pkg "$pkg") || die "pacote não encontrado: $pkg"
    newv=$(sed -n '1p' "$path/version")
    oldv=$(sed -n '1p' "$ARIA_INSTALLED/$pkg/version" 2>/dev/null || echo "")
    [ -z "$oldv" ] && die "$pkg não está instalado"
    if [ "$(version_major "$newv")" -gt "$(version_major "$oldv")" ]; then
        msg "↑ upgrade major: $pkg $oldv -> $newv"
        aria_build "$pkg"
        aria_install "${pkg}-${newv}.tar.${ARIA_COMPRESS}"
    else
        msg "upgrade ignorado (não é major): $oldv -> $newv"
    fi
}

# ===== sync (git) =====
aria_sync(){
    IFS=:; for repo in $ARIA_PATH; do IFS=' '
        if [ -d "$repo/.git" ]; then
            msg "↺ git pull: $repo"
            (cd "$repo" && git fetch --all --tags && git pull --ff-only)
            [ -f "$repo/.gitmodules" ] && (cd "$repo" && git submodule update --init --recursive)
        fi
    done
}

# ===== checksum =====
aria_checksum_verify(){
    pkg="$1"
    path=$(aria_find_pkg "$pkg") || die "pacote não encontrado: $pkg"
    set -- $(aria_read_meta "$path")
    ver="$1"; srcs="$2"; chks="$3"
    ensure_dirs
    aria_fetch_sources "$path" "$srcs" "$chks"
    msg "✓ checksums OK para $pkg-$ver"
}

aria_mkchecksum(){
    pkg="$1"
    path=$(aria_find_pkg "$pkg") || die "pacote não encontrado: $pkg"
    srcs=$(sed 's/#.*$//' "$path/sources" 2>/dev/null | sed '/^[[:space:]]*$/d' || true)
    [ -n "$srcs" ] || die "sources vazio em $pkg"
    ensure_dirs
    : > "$path/checksums"
    echo "$srcs" | while IFS= read -r url; do
        [ -n "$url" ] || continue
        case "$url" in
            http://*|https://*)
                [ -f "$ARIA_SRC/$(base "$url")" ] || (cd "$ARIA_SRC" && curl -L -O "$url")
                fn="$ARIA_SRC/$(base "$url")"
                ;;
            file://*) fn="${url#file://}";;
            /*)       fn="$url";;
            *)       die "fonte não suportada: $url";;
        esac
        sha256sum "$fn" | awk '{print $1}' >> "$path/checksums"
    done
    msg "✓ checksums gerados em $path/checksums"
}

# ===== list/help/entrada =====
aria_list(){ ls -1 "$ARIA_INSTALLED" 2>/dev/null | sed '/^[[:space:]]*$/d' || true; }

aria_help(){
cat <<'EOF'
ARIA - gerenciador de pacotes minimalista

Uso:
  aria sync                              # sincroniza repositórios git (ARIA_PATH)
  aria build <pkg>                       # compila e cria tarball (fake root=$1)
  aria install <pkg>|<pacote.tar.*>      # instala (tarball local ou nome)
  aria remove <pkg>                      # remove e limpa diretórios vazios + hooks
  aria list                              # lista instalados
  aria revdep <pkg>                      # reconstrói dependentes e corrige ELF quebrados
  aria rebuild-world                     # recompila todo o sistema por ordem de deps
  aria upgrade <pkg>                     # apenas upgrade de versão major
  aria checksum <pkg>                    # verifica checksums
  aria mkchecksum <pkg>                  # gera checksums (sha256) a partir de sources
  aria help                              # esta ajuda

Arquivos por pacote (estilo KISS):
  build, version, sources, checksums, depends, provides (opcional), hooks/* (opcional)
  - depends: "nome", "nome make", "nome ?" (opcional)
  - provides: linhas "virtual [versao]"
Hooks:
  Globais: /var/db/aria/hooks/{pre-build,post-build,pre-install,post-install,pre-remove,post-remove}/
  Pacote:  <repo>/<pkg>/hooks/{pre-build,post-*,pre-*,post-*}/
  Vars: ARIA_STAGE, ARIA_PKG, ARIA_VER, ARIA_FAKE_ROOT, ARIA_PATH_PKG, ARIA_WORKDIR, ARIA_ROOT

Flags/Env:
  --force            ignora falhas pontuais (download/hook/remover arquivo)
  ARIA_COMPRESS      gz|xz|zst (padrão: gz)
  ARIA_WITH_OPT      1 inclui dependências marcadas com '?'
  ARIA_PROMPT=0      desabilita prompts
EOF
}

# ------- entrada -------
ARIA_FORCE=0
case "$1" in
  --force) ARIA_FORCE=1; shift ;;
esac
cmd="${1:-help}"; shift || true
case "$cmd" in
  sync)             aria_sync "$@" ;;
  build|b)          aria_build "$@" ;;
  install|i)        aria_install "$@" ;;
  remove|r)         aria_remove "$@" ;;
  list|l)           aria_list "$@" ;;
  revdep)           aria_revdep "$@" ;;
  rebuild-world)    aria_rebuild_world "$@" ;;
  upgrade)          aria_upgrade "$@" ;;
  checksum)         aria_checksum_verify "$@" ;;
  mkchecksum)       aria_mkchecksum "$@" ;;
  help|-h|--help|*) aria_help ;;
esac
