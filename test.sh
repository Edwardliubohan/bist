#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/tests build/module-cache
xcrun swiftc -module-cache-path "$PWD/build/module-cache" Sources/BistCore.swift Sources/LocalInbox.swift Tests/CoreTests.swift -o build/tests/core
build/tests/core
xcrun swiftc -module-cache-path "$PWD/build/module-cache" Sources/LocalInbox.swift Tests/InboxTests.swift -o build/tests/inbox
build/tests/inbox
xcrun swiftc -module-cache-path "$PWD/build/module-cache" Sources/PanelGeometry.swift Tests/PanelGeometryTests.swift -o build/tests/panel
build/tests/panel
xcrun swiftc -module-cache-path "$PWD/build/module-cache" Sources/AgentResults.swift Tests/AgentResultsTests.swift -o build/tests/agent-results
build/tests/agent-results
xcrun swiftc -module-cache-path "$PWD/build/module-cache" Sources/BistCore.swift Sources/LocalInbox.swift Sources/TaskViewState.swift Tests/TaskViewStateTests.swift -o build/tests/task-view-state
build/tests/task-view-state
