# Diretórios principais
export ARIA_ROOT="/"
export ARIA_PATH="/var/db/aria/repo/core:/var/db/aria/repo/extra"
export ARIA_INSTALLED="/var/db/aria/installed"
export ARIA_CACHE="/var/cache/aria"
export ARIA_SRC="$ARIA_CACHE/sources"
export ARIA_BUILD="$ARIA_CACHE/build"

# Comportamento
export ARIA_COMPRESS="gz"   # ou xz, zst...
export ARIA_SU="sudo"       # ou doas, su -c
export ARIA_COLOR=1         # 0 = sem cores
export ARIA_DEBUG=0         # 1 = debug (set -x)
export ARIA_PROMPT=1        # 0 = não perguntar
