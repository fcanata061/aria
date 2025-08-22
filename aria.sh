#!/bin/sh
# ARIA Package Manager - minimalista

set -e

[ "$ARIA_DEBUG" = 1 ] && set -x

color() { [ "$ARIA_COLOR" = 1 ] && printf "\033[1;32m%s\033[0m\n" "$*" || echo "$*"; }

# Busca pacote nos repositórios
aria_find_pkg() {
    for repo in $(echo "$ARIA_PATH" | tr ':' ' '); do
        [ -d "$repo/$1" ] && { echo "$repo/$1"; return 0; }
    done
    return 1
}

# Instala pacote
aria_install() {
    pkg=$1
    path=$(aria_find_pkg "$pkg") || { echo "Pacote $pkg não encontrado"; exit 1; }

    # Carregar metadados
    ver=$(cat "$path/version")
    src=$(cat "$path/sources")
    sum=$(cat "$path/checksums")

    mkdir -p "$ARIA_SRC" "$ARIA_BUILD"

    # Baixar fontes
    cd "$ARIA_SRC"
    [ ! -f "$(basename "$src")" ] && curl -LO "$src"

    # Verificar checksum
    echo "$sum  $(basename "$src")" | sha256sum -c -

    # Extrair e compilar
    cd "$ARIA_BUILD"
    rm -rf "$pkg-$ver"
    tar xf "$ARIA_SRC/$(basename "$src")"
    cd "$pkg-$ver"
    sh "$path/build"

    # Registrar instalação
    mkdir -p "$ARIA_INSTALLED/$pkg"
    echo "$ver" > "$ARIA_INSTALLED/$pkg/version"
    find "$ARIA_ROOT" -type f > "$ARIA_INSTALLED/$pkg/manifest"

    color "✓ Instalado $pkg-$ver"
}

# Remover pacote
aria_remove() {
    pkg=$1
    [ ! -d "$ARIA_INSTALLED/$pkg" ] && { echo "$pkg não está instalado"; exit 1; }
    xargs rm -f < "$ARIA_INSTALLED/$pkg/manifest"
    rm -rf "$ARIA_INSTALLED/$pkg"
    color "✗ Removido $pkg"
}

# Listar pacotes instalados
aria_list() {
    ls "$ARIA_INSTALLED"
}

# Entry point
case "$1" in
    i|install) shift; aria_install "$@";;
    r|remove)  shift; aria_remove "$@";;
    l|list)    aria_list;;
    *) echo "Uso: aria [install|remove|list] pacote";;
esac
