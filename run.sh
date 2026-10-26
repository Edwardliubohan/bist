#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
./build.sh
if [[ " $* " == *" --demo "* ]]; then
  export BIST_DATA_DIR="$PWD/.demo-data"
else
  export BIST_DATA_DIR="${BIST_DATA_DIR:-$PWD/.local-data}"
fi
exec "$PWD/build/bist.app/Contents/MacOS/bist" "$@"
