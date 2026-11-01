#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/tests build/module-cache
xcrun swiftc -module-cache-path "$PWD/build/module-cache" -I Shared/Sources/CSQLite Shared/Sources/BistSync/*.swift Tests/SyncStorageTests.swift -lsqlite3 -o build/tests/sync-storage
build/tests/sync-storage
