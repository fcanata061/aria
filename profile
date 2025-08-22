# Raiz e repositórios
export ARIA_ROOT="/"
export ARIA_PATH="/var/db/aria/repo/core:/var/db/aria/repo/extra"
export ARIA_INSTALLED="/var/db/aria/installed"

# Cache
export ARIA_CACHE="/var/cache/aria"
export ARIA_SRC="$ARIA_CACHE/sources"
export ARIA_BUILD="$ARIA_CACHE/build"

# Opções
export ARIA_COMPRESS="gz"   # gz | xz | zst
export ARIA_COLOR=1
export ARIA_DEBUG=0
export ARIA_PROMPT=1
export ARIA_SU="sudo"
export ARIA_WITH_OPT=0      # 1 = considera deps opcionais (marcadas com '?')
