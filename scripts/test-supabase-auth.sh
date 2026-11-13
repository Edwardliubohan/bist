#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/tests build/module-cache
if [[ ! -f Sources/SupabaseAuth.swift ]]; then
  print -u2 'FAIL Supabase email authentication is not implemented'
  exit 1
fi
xcrun swiftc -module-cache-path "$PWD/build/module-cache" \
  Sources/SupabaseAuth.swift Tests/SupabaseAuthTests.swift \
  -o build/tests/supabase-auth
build/tests/supabase-auth
