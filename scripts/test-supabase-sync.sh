#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build/tests build/module-cache
for BIST_SUPABASE_SUITE in SupabaseAccountTests SupabaseSyncTests SupabaseCoordinatorTests; do
  xcrun swiftc -whole-module-optimization -I Shared/Sources/CSQLite -module-cache-path "$PWD/build/module-cache" \
    Shared/Sources/BistSync/*.swift Sources/BistCore.swift Sources/LocalInbox.swift \
    Sources/NoteStore.swift Sources/BistSync.swift Sources/CloudKitSync.swift \
    Sources/SupabaseAuth.swift Sources/SupabaseAccount.swift Sources/SupabaseSync.swift \
    "Tests/$BIST_SUPABASE_SUITE.swift" -lsqlite3 -o "build/tests/$BIST_SUPABASE_SUITE"
  "build/tests/$BIST_SUPABASE_SUITE"
done
