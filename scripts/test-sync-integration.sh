#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build/tests build/module-cache
xcrun swiftc -I Shared/Sources/CSQLite -module-cache-path "$PWD/build/module-cache" \
  Shared/Sources/BistSync/*.swift Sources/BistCore.swift Sources/LocalInbox.swift \
  Sources/NoteStore.swift Sources/BistSync.swift Sources/CloudKitSync.swift \
  Tests/SyncIntegrationTests.swift -lsqlite3 -o build/tests/sync-integration
build/tests/sync-integration

xcrun swiftc -I Shared/Sources/CSQLite -module-cache-path "$PWD/build/module-cache" \
  Shared/Sources/BistSync/*.swift Sources/BistCore.swift Sources/LocalInbox.swift \
  Sources/NoteStore.swift Sources/BistSync.swift Sources/CloudKitSync.swift \
  Tests/SyncNoteRecoveryTests.swift -lsqlite3 -o build/tests/sync-note-recovery
build/tests/sync-note-recovery

xcrun swiftc -I Shared/Sources/CSQLite -module-cache-path "$PWD/build/module-cache" \
  Shared/Sources/BistSync/*.swift Sources/BistCore.swift Sources/LocalInbox.swift \
  Sources/NoteStore.swift Sources/BistSync.swift Sources/CloudKitSync.swift \
  Tests/SyncSamplesTests.swift -lsqlite3 -o build/tests/sync-samples
build/tests/sync-samples

xcrun swiftc -I Shared/Sources/CSQLite -module-cache-path "$PWD/build/module-cache" \
  Shared/Sources/BistSync/*.swift Sources/BistCore.swift Sources/LocalInbox.swift \
  Sources/NoteStore.swift Sources/BistSync.swift Sources/CloudKitSync.swift \
  Tests/CloudKitPolicyTests.swift -lsqlite3 -o build/tests/cloudkit-policy
build/tests/cloudkit-policy

for BIST_REVIEW_SUITE in SyncReviewTests SyncPersistenceReviewTests CloudKitStateTests SyncOrderTests SyncProjectionExportTests SyncExternalNoteFailureTests; do
  xcrun swiftc -whole-module-optimization -I Shared/Sources/CSQLite -module-cache-path "$PWD/build/module-cache" \
    Shared/Sources/BistSync/*.swift Sources/BistCore.swift Sources/LocalInbox.swift \
    Sources/NoteStore.swift Sources/BistSync.swift Sources/CloudKitSync.swift \
    "Tests/$BIST_REVIEW_SUITE.swift" -lsqlite3 -o "build/tests/$BIST_REVIEW_SUITE"
  "build/tests/$BIST_REVIEW_SUITE"
done
