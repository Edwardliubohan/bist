#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/tests build/module-cache
xcrun swiftc -module-cache-path "$PWD/build/module-cache" Sources/BistCore.swift Sources/LocalInbox.swift Tests/CoreTests.swift -o build/tests/core
build/tests/core
xcrun swiftc -module-cache-path "$PWD/build/module-cache" Sources/LocalInbox.swift Tests/InboxTests.swift -o build/tests/inbox
build/tests/inbox
