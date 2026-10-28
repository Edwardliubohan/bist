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
xcrun swiftc -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/CornerHoverTests.swift -o build/tests/corner-hover
build/tests/corner-hover
xcrun swiftc -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/PanelLifecycleTests.swift -o build/tests/panel-lifecycle
build/tests/panel-lifecycle
xcrun swiftc -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/LocalSessionTests.swift -o build/tests/local-sessions
build/tests/local-sessions
xcrun swiftc -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/SessionBrowserTests.swift -o build/tests/session-browser
build/tests/session-browser
xcrun swiftc -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/PersistenceTests.swift -o build/tests/persistence
build/tests/persistence
python3 scripts/test-data-location.py

xcrun swiftc -module-cache-path "$PWD/build/module-cache" Sources/BistCore.swift Sources/LocalInbox.swift Sources/NoteStore.swift Tests/NoteStoreTests.swift -o build/tests/note-store
build/tests/note-store

xcrun swiftc -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/TextEntryFocusTests.swift -o build/tests/text-entry-focus
build/tests/text-entry-focus

xcrun swiftc -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/NativeCaretTests.swift -o build/tests/native-caret
build/tests/native-caret

xcrun swiftc -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/SessionInboxTests.swift -o build/tests/session-inbox
build/tests/session-inbox

xcrun swiftc -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/ColdLaunchCaretTests.swift -o build/tests/cold-launch-caret
build/tests/cold-launch-caret

xcrun swiftc -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/InactiveTextEntryTests.swift -o build/tests/inactive-text-entry
build/tests/inactive-text-entry
build/tests/inactive-text-entry --note

xcrun swiftc -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/T3SessionTests.swift -o build/tests/t3-sessions
build/tests/t3-sessions

xcrun swiftc -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/BobotStoreTests.swift -o build/tests/bobot-store
build/tests/bobot-store
python3 Tests/test_bobot_bridge.py

xcrun swiftc -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/BobotFlowTests.swift -o build/tests/bobot-flow
build/tests/bobot-flow

xcrun swiftc -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/CompletionRetentionTests.swift -o build/tests/completion-retention
build/tests/completion-retention
