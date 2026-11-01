#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
python3 iOS/validate-project.py
mkdir -p build/tests build/module-cache
xcrun swiftc -D BIST_TESTING -I Shared/Sources/CSQLite -module-cache-path "$PWD/build/module-cache" \
  Shared/Sources/BistSync/*.swift Sources/*.swift iOS/PhoneTaskEditing.swift \
  iOS/Tests/PhoneTaskEditingTests.swift -lsqlite3 -o build/tests/phone-editing
build/tests/phone-editing
