#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/tests build/module-cache
compile() { xcrun swiftc -whole-module-optimization -I "$PWD/Shared/Sources/CSQLite" "$PWD"/Shared/Sources/BistSync/*.swift -lsqlite3 "$@"; }
compile -D BIST_CHECKLIST_TESTS -module-cache-path "$PWD/build/module-cache" Sources/BistCore.swift Sources/LocalInbox.swift Sources/TaskViewState.swift Tests/CoreTests.swift -o build/tests/core
build/tests/core
compile -module-cache-path "$PWD/build/module-cache" Sources/LocalInbox.swift Tests/InboxTests.swift -o build/tests/inbox
build/tests/inbox
compile -module-cache-path "$PWD/build/module-cache" Sources/PanelGeometry.swift Tests/PanelGeometryTests.swift -o build/tests/panel
build/tests/panel
compile -module-cache-path "$PWD/build/module-cache" Sources/PanelMotion.swift Tests/PanelMotionTests.swift -o build/tests/panel-motion
build/tests/panel-motion
compile -module-cache-path "$PWD/build/module-cache" Sources/AgentResults.swift Tests/AgentResultsTests.swift -o build/tests/agent-results
build/tests/agent-results
compile -module-cache-path "$PWD/build/module-cache" Sources/BistCore.swift Sources/LocalInbox.swift Sources/TaskViewState.swift Tests/TaskViewStateTests.swift -o build/tests/task-view-state
build/tests/task-view-state
compile -whole-module-optimization -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/TaskDisclosureTests.swift -o build/tests/task-disclosure
build/tests/task-disclosure
python3 scripts/test-logo.py
compile -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/CornerHoverTests.swift -o build/tests/corner-hover
build/tests/corner-hover
compile -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/PanelLifecycleTests.swift -o build/tests/panel-lifecycle
build/tests/panel-lifecycle
compile -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/PanelResizeTests.swift -o build/tests/panel-resize
build/tests/panel-resize
compile -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/LocalSessionTests.swift -o build/tests/local-sessions
build/tests/local-sessions
compile -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/SessionBrowserTests.swift -o build/tests/session-browser
build/tests/session-browser
compile -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/PersistenceTests.swift -o build/tests/persistence
build/tests/persistence
python3 scripts/test-data-location.py

compile -module-cache-path "$PWD/build/module-cache" Sources/BistCore.swift Sources/LocalInbox.swift Sources/NoteStore.swift Tests/NoteStoreTests.swift -o build/tests/note-store
build/tests/note-store
compile -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/NoteScrollTests.swift -o build/tests/note-scroll
build/tests/note-scroll

compile -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/TextEntryFocusTests.swift -o build/tests/text-entry-focus
build/tests/text-entry-focus

compile -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/NativeCaretTests.swift -o build/tests/native-caret
build/tests/native-caret

compile -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/SessionInboxTests.swift -o build/tests/session-inbox
build/tests/session-inbox

compile -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/ColdLaunchCaretTests.swift -o build/tests/cold-launch-caret
build/tests/cold-launch-caret

compile -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/InactiveTextEntryTests.swift -o build/tests/inactive-text-entry
build/tests/inactive-text-entry
build/tests/inactive-text-entry --note

compile -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/T3SessionTests.swift -o build/tests/t3-sessions
build/tests/t3-sessions

compile -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/BobotStoreTests.swift -o build/tests/bobot-store
build/tests/bobot-store
python3 Tests/test_bobot_bridge.py

compile -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/BobotFlowTests.swift -o build/tests/bobot-flow
build/tests/bobot-flow

compile -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/CompletionRetentionTests.swift -o build/tests/completion-retention
build/tests/completion-retention

compile -D BIST_TESTING -module-cache-path "$PWD/build/module-cache" Sources/*.swift Tests/AppearanceTests.swift -o build/tests/appearance
build/tests/appearance

./scripts/test-sync-storage.sh
./scripts/test-sync-integration.sh
./scripts/test-supabase-auth.sh
./scripts/test-supabase-sync.sh
./iOS/test-phone.sh
