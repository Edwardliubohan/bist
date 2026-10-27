#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/tests build/module-cache
xcrun swiftc -D BIST_CHECKLIST_TESTS -module-cache-path "$PWD/build/module-cache" Sources/BistCore.swift Sources/LocalInbox.swift Sources/TaskViewState.swift Tests/CoreTests.swift -o build/tests/core
build/tests/core
xcrun swiftc -module-cache-path "$PWD/build/module-cache" Sources/LocalInbox.swift Tests/InboxTests.swift -o build/tests/inbox
build/tests/inbox
xcrun swiftc -module-cache-path "$PWD/build/module-cache" Sources/PanelGeometry.swift Tests/PanelGeometryTests.swift -o build/tests/panel
build/tests/panel
xcrun swiftc -module-cache-path "$PWD/build/module-cache" Sources/PanelMotion.swift Tests/PanelMotionTests.swift -o build/tests/panel-motion
build/tests/panel-motion
xcrun swiftc -module-cache-path "$PWD/build/module-cache" Sources/AgentResults.swift Tests/AgentResultsTests.swift -o build/tests/agent-results
build/tests/agent-results
xcrun swiftc -module-cache-path "$PWD/build/module-cache" Sources/BistCore.swift Sources/LocalInbox.swift Sources/TaskViewState.swift Tests/TaskViewStateTests.swift -o build/tests/task-view-state
build/tests/task-view-state
python3 scripts/test-logo.py
xcrun swiftc -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/PanelLifecycleTests.swift -o build/tests/panel-lifecycle
build/tests/panel-lifecycle
xcrun swiftc -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/LocalSessionTests.swift -o build/tests/local-sessions
build/tests/local-sessions
xcrun swiftc -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/SessionBrowserTests.swift -o build/tests/session-browser
build/tests/session-browser
