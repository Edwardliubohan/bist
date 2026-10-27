#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
./build.sh
exec "$PWD/build/bist.app/Contents/MacOS/bist" "$@"
