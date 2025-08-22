#!/bin/sh
# ARIA - Package Manager minimalista (estilo KISS)
# Licença: do-what-you-want (for fun)

set -e

[ "${ARIA_DEBUG:-0}" = "1" ] && set -x

# ---------- util ----------
die(){ echo "aria: $*" >&2; exit 1; }
yesno(){ [ "${ARIA_PROMPT:-1}" = "0" ] && return 0; printf "%s [y/N] " "$1"; read -r a; [ "$a" = "y" ] || [ "$a" = "Y" ]; }
msg(){ if [ "${ARIA_COLOR:-1}" = "1" ]; then printf "\033[1;32m%s\033[0m\n" "$*"; else echo "$*"; fi; }
ensure_dirs(){ mkdir -p "$ARIA_SRC" "$ARIA_BUILD" "$ARIA_INSTALLED"; }

compress_write(){
    # stdin -> pacote $1 conforme $ARIA_COMPRESS
    out="$1"
    case "${ARIA_COMPRESS:-gz}" in
        gz)  gzip  -9  > "$out" ;;
        xz)  xz    -9e > "$out" ;;
        zst) zstd  -19 -q -o "$out" ;;
        *) die "compressor desconhecido: $ARIA_COMPRESS" ;;
    esac
}

decompress_tar(){
    # extrai arquivo $1 no CWD
    f="$1"
    case "$f" in
        *.tar.gz|*.tgz)   tar xzf "$f" ;;
        *.tar.xz)         tar xJf "$f" ;;
        *.tar.zst|*.tzst) zstd -dc "$f" | tar xf - ;;
        *) die "não sei descompactar: $f" ;;
    esac
}

base(){ basename -- "$1"; }

# ---------- localização ----------
aria_find_pkg(){
    name="$1"
    IFS=:; for repo in $ARIA_PATH; do IFS=' '
        [ -d "$repo/$name" ] && { printf "%s\n" "$repo/$name"; return 0; }
    done
    return 1
}

# ---------- leitura de metadados ----------
aria_read_meta(){
    # $1 = path do pacote
    p="$1"
    [ -f "$p/version" ]   || die "sem version em $p"
    ver=$(sed -n '1p' "$p/version")
    srcs=""
    [ -f "$p/sources" ]   && srcs=$(sed 's/#.*$//' "$p/sources" | sed '/^[[:space:]]*$/d')
    chks=""
    [ -f "$p/checksums" ] && chks=$(sed 's/#.*$//' "$p/checksums" | sed '/^[[:space:]]*$/d')
    deps=""
    if [ -f "$p/depends" ]; then
        if [ "${ARIA_WITH_OPT:-0}" = "1" ]; then
            deps=$(sed 's/#.*$//' "$p/depends" | sed '/^[[:space:]]*$/d; s/?$//')
        else
            deps=$(sed 's/#.*$//' "$p/depends" | sed '/^[[:space:]]*$/d; /[[:space:]]\?$/d')
        fi
    fi
    printf "%s\n%s\n%s\n%s\n" "$ver" "$srcs" "$chks" "$deps"
}

# ---------- download + checksum ----------
aria_fetch_sources(){
    # $1 = pacote path, $2 = lista fontes, $3 = lista checksums
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
        # checksum
        sum=$(printf "%s\n" "$chks" | sed -n "${i}p")
        [ -n "$sum" ] || die "faltou checksum #$i para $(base "$url")"
        ( cd "$ARIA_SRC" && printf "%s  %s\n" "$sum" "$(base "$url")" | sha256sum -c - ) || die "checksum falhou: $(base "$url")"
        i=$((i+1))
    done
}

# ---------- grafo de dependências ----------
_seen=""; _order=""
dep_mark(){ echo "$_seen" | grep -qx "$1" && return 0 || return 1; }
dep_push(){ _order=$_order$(printf "%s\n" "$1"); }

dep_resolve_dfs(){
    # DFS + memo simples
    pkg="$1"
    dep_mark "$pkg" && return 0
    _seen="$_seen
$pkg"
    path=$(aria_find_pkg "$pkg") || die "dep não encontrado: $pkg"
    set -- $(aria_read_meta "$path")
    # shellcheck disable=SC2034
    ver="$1"; srcs="$2"; chks="$3"; deps="$4"
    echo "$deps" | while IFS= read -r d; do
        [ -z "$d" ] && continue
        dep_resolve_dfs "$d"
    done
    dep_push "$pkg"
}

dep_order(){
    # entrada: lista de pacotes (nomes)
    _seen=""; _order=""
    for p in "$@"; do dep_resolve_dfs "$p"; done
    printf "%s" "$_order" | sed '/^[[:space:]]*$/d' | awk '!seen[$0]++'
}

# ---------- build (estilo KISS) ----------
aria_build(){
    pkg="$1"
    path=$(aria_find_pkg "$pkg") || die "pacote não encontrado: $pkg"
    set -- $(aria_read_meta "$path")
    ver="$1"; srcs="$2"; chks="$3"; deps="$4"

    # 1) garantir dependências (build-order)
    if [ -n "$deps" ]; then
        msg "↳ resolvendo dependências"
        order=$(dep_order $deps)
        for d in $order; do
            # se não instalado/sem pacote pronto, tentar build
            [ -d "$ARIA_INSTALLED/$d" ] && continue
            aria_build "$d"
            aria_install "${d}-$(sed -n '1p' "$(aria_find_pkg "$d")/version").tar.${ARIA_COMPRESS:-gz}"
        done
    fi

    ensure_dirs

    # 2) baixar + validar
    [ -n "$srcs" ] && aria_fetch_sources "$path" "$srcs" "$chks"

    # 3) preparar diretórios
    work="$ARIA_BUILD/${pkg}-${ver}"
    fakeroot="$ARIA_BUILD/${pkg}-pkg"
    rm -rf "$work" "$fakeroot"
    mkdir -p "$work" "$fakeroot"

    # 4) extrair fontes (todas, na ordem)
    cd "$work"
    echo "$srcs" | while IFS= read -r url; do
        [ -n "$url" ] || continue
        fn="$ARIA_SRC/$(base "${url#file://}")"
        [ -f "$fn" ] || fn="$ARIA_SRC/$(base "$url")"
        decompress_tar "$fn" || true
    done

    # 5) executar script build do pacote, passando $1 (fake root)
    [ -x "$path/build" ] || chmod +x "$path/build" 2>/dev/null || true
    msg "⚙️  build $pkg-$ver"
    ( cd "$work" && sh "$path/build" "$fakeroot" )

    # 6) manifesto
    ( cd "$fakeroot" && find . -type f | sed 's|^\./||' ) > "$ARIA_BUILD/${pkg}.manifest"

    # 7) criar pacote binário
    out="${pkg}-${ver}.tar.${ARIA_COMPRESS:-gz}"
    ( cd "$fakeroot" && tar -c . ) | compress_write "$out"

    msg "✓ build pronto: $out"
}

# ---------- install ----------
aria_install(){
    arg="$1"
    ensure_dirs

    pkgfile=""
    if [ -f "$arg" ]; then
        pkgfile="$arg"
        basefn=$(base "$pkgfile")
        pkg="${basefn%%-*}"
        ver_ext="${basefn#${pkg}-}"
        ver="${ver_ext%%.tar.*}"
    else
        # nome: tenta usar tarball do CWD; se não houver, faz build
        pkg="$arg"
        path=$(aria_find_pkg "$pkg") || die "pacote não encontrado: $pkg"
        ver=$(sed -n '1p' "$path/version")
        pkgfile="${pkg}-${ver}.tar.${ARIA_COMPRESS:-gz}"
        [ -f "$pkgfile" ] || { aria_build "$pkg"; }
        [ -f "$pkgfile" ] || die "não achei $pkgfile para instalar"
    fi

    msg "⇣ instalando $pkg-$ver em $ARIA_ROOT"
    tmp="$ARIA_BUILD/.inst-$pkg"
    rm -rf "$tmp"; mkdir -p "$tmp"
    decompress_tar "$pkgfile"
    # o pacote foi extraído no CWD; garanta extração segura:
    rm -rf "$tmp"; mkdir -p "$tmp"
    case "$pkgfile" in
        *.zst|*.tzst) zstd -dc "$pkgfile" | (cd "$tmp" && tar xpf -) ;;
        *.xz)         xz   -dc "$pkgfile" | (cd "$tmp" && tar xpf -) ;;
        *)            gzip -dc "$pkgfile" | (cd "$tmp" && tar xpf -) || (cd "$tmp" && tar xpf "$pkgfile") ;;
    esac

    ( cd "$tmp" && tar -c . ) | ( cd "$ARIA_ROOT" && ${ARIA_SU:-sudo} tar xpf - )

    # registrar
    inst="$ARIA_INSTALLED/$pkg"
    rm -rf "$inst"; mkdir -p "$inst"
    echo "$ver" > "$inst/version"

    # dependências registradas (do repo)
    if path=$(aria_find_pkg "$pkg"); then
        if [ -f "$path/depends" ]; then
            if [ "${ARIA_WITH_OPT:-0}" = "1" ]; then sed 's/#.*$//' "$path/depends" | sed '/^[[:space:]]*$/d; s/?$//' > "$inst/depends"
            else sed 's/#.*$//' "$path/depends" | sed '/^[[:space:]]*$/d; /[[:space:]]\?$/d' > "$inst/depends"
            fi
        else : > "$inst/depends"; fi
    else : > "$inst/depends"; fi

    # manifest gerado no build
    if [ -f "$ARIA_BUILD/${pkg}.manifest" ]; then
        cp "$ARIA_BUILD/${pkg}.manifest" "$inst/manifest"
    else
        # fallback: registrar o que acabou de ser extraído
        ( cd "$tmp" && find . -type f | sed 's|^\./||' ) > "$inst/manifest"
    fi

    rm -rf "$tmp"
    msg "✓ instalado: $pkg-$ver"
}

# ---------- remove (limpo) ----------
aria_remove(){
    pkg="$1"
    inst="$ARIA_INSTALLED/$pkg"
    [ -d "$inst" ] || die "$pkg não está instalado"

    yesno "Remover $pkg?" || die "abortado"

    # remover arquivos listados no manifest
    if [ -f "$inst/manifest" ]; then
        # remover arquivos
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            rm -f "$ARIA_ROOT/$f" 2>/dev/null || [ "${ARIA_FORCE:-0}" = "1" ] || die "falha removendo $f (use --force)"
        done < "$inst/manifest"
        # remover diretórios vazios relacionados
        awk -F/ '{
            path="";
            for(i=1;i<NF;i++){ path=path $i "/"; print path }
        }' "$inst/manifest" | sort -r | uniq | while read -r d; do
            rmdir "$ARIA_ROOT/$d" 2>/dev/null || true
        done
    fi
    rm -rf "$inst"
    msg "✗ removido: $pkg"
}

# ---------- revdep (evoluído) ----------
aria_revdep(){
    # encontra dependentes de $1 e tenta reconstruir/instalar
    target="$1"
    [ -n "$target" ] || die "uso: aria revdep <pacote>"

    # 1) quem depende do target?
    deps=""
    for p in "$ARIA_INSTALLED"/*; do
        [ -d "$p" ] || continue
        name=$(base "$p")
        [ "$name" = "installed" ] && continue
        if grep -qx "$target" "$p/depends" 2>/dev/null; then
            deps="$deps $name"
        fi
    done

    # 2) também tentar checar binários quebrados (ELF) do target e dependentes
    check_pkgs="$target $deps"
    broken=""
    for p in $check_pkgs; do
        man="$ARIA_INSTALLED/$p/manifest"
        [ -f "$man" ] || continue
        while IFS= read -r f; do
            fp="$ARIA_ROOT/$f"
            [ -f "$fp" ] || continue
            if file "$fp" 2>/dev/null | grep -q "ELF"; then
                if ! ldd "$fp" 2>/dev/null | grep -q "not found"; then
                    :
                else
                    broken="$broken $p"
                    break
                fi
            fi
        done < "$man"
    done

    # 3) reordena por dependências e recompila
    tofix=$(printf "%s %s\n" "$deps" "$broken" | tr ' ' '\n' | sed '/^[[:space:]]*$/d' | sort -u)
    [ -z "$tofix" ] && { msg "revdep: nada a fazer"; return 0; }

    order=$(dep_order $tofix)
    for p in $order; do
        msg "↻ revdep rebuild: $p"
        aria_build "$p"
        ver=$(sed -n '1p' "$(aria_find_pkg "$p")/version")
        aria_install "${p}-${ver}.tar.${ARIA_COMPRESS:-gz}"
    done
}

# ---------- rebuild de todo o sistema ----------
aria_rebuild_world(){
    pkgs=$(ls -1 "$ARIA_INSTALLED" 2>/dev/null | sed '/^[[:space:]]*$/d')
    [ -n "$pkgs" ] || { msg "nada instalado"; return 0; }
    order=$(dep_order $pkgs)
    for p in $order; do
        msg "↻ rebuild: $p"
        aria_build "$p"
        ver=$(sed -n '1p' "$(aria_find_pkg "$p")/version")
        aria_install "${p}-${ver}.tar.${ARIA_COMPRESS:-gz}"
    done
}

# ---------- upgrade apenas major ----------
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
        aria_install "${pkg}-${newv}.tar.${ARIA_COMPRESS:-gz}"
    else
        msg "upgrade ignorado (não é major): $oldv -> $newv"
    fi
}

# ---------- sync com repositórios git ----------
aria_sync(){
    IFS=:; for repo in $ARIA_PATH; do IFS=' '
        if [ -d "$repo/.git" ]; then
            msg "↺ git pull: $repo"
            (cd "$repo" && git fetch --all --tags && git pull --ff-only)
        fi
        # submódulos opcionais
        if [ -f "$repo/.gitmodules" ]; then
            (cd "$repo" && git submodule update --init --recursive)
        fi
    done
}

# ---------- checksum ----------
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
    # baixar se necessário e gerar
    for url in $srcs; do
        case "$url" in
            http://*|https://*)
                [ -f "$ARIA_SRC/$(base "$url")" ] || (cd "$ARIA_SRC" && curl -L -O "$url")
                fn="$ARIA_SRC/$(base "$url")"
                ;;
            file://*) fn="${url#file://}";;
            /*)       fn="$url";;
            *)       die "fonte não suportada: $url";;
        esac
        sha256sum "$fn" | awk '{print $1}'
    done > "$path/checksums"
    msg "✓ checksums gerados em $path/checksums"
}

# ---------- help ----------
aria_help(){
cat <<'EOF'
ARIA - gerenciador de pacotes minimalista

Uso:
  aria sync                              # sincroniza repositórios git do ARIA_PATH
  aria build <pkg>                       # compila e cria tarball (fake root = $1)
  aria install <pkg>|<pacote.tar.*>      # instala (aceita tarball ou nome)
  aria remove <pkg>                      # remove e limpa diretórios vazios
  aria list                              # lista instalados
  aria revdep <pkg>                      # reconstrói dependentes e corrige bins quebrados
  aria rebuild-world                     # recompila todo o sistema por ordem de dependências
  aria upgrade <pkg>                     # só permite upgrade de versão major
  aria checksum <pkg>                    # verifica checksums (baixa se preciso)
  aria mkchecksum <pkg>                  # gera checksums (sha256) baseado em sources
  aria help                              # esta ajuda

Flags:
  --force        ignora falhas pontuais (download/remoção)
  ARIA_COMPRESS  gz|xz|zst (padrão: gz)
  ARIA_WITH_OPT  1 inclui dependências marcadas com '?'
EOF
}

# ---------- list ----------
aria_list(){ ls -1 "$ARIA_INSTALLED" 2>/dev/null | sed '/^[[:space:]]*$/d' || true; }

# ---------- entrada ----------
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
