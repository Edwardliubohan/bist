#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "${BIST_POSTGRES_BIN:-}" ]]; then
  http_pg_bin="$BIST_POSTGRES_BIN"
elif command -v initdb >/dev/null 2>&1; then
  http_pg_bin="$(dirname "$(command -v initdb)")"
else
  http_pg_bin=""
  if command -v pg_config >/dev/null 2>&1; then
    http_config_bin="$(pg_config --bindir)"
    if [[ -x "$http_config_bin/initdb" ]]; then http_pg_bin="$http_config_bin"; fi
  fi
  for http_candidate in /opt/homebrew/opt/postgresql@17/bin /opt/homebrew/opt/postgresql@15/bin /opt/homebrew/opt/postgresql@14/bin /usr/lib/postgresql/18/bin /usr/lib/postgresql/17/bin /usr/lib/postgresql/16/bin /usr/lib/postgresql/15/bin /usr/lib/postgresql/14/bin; do
    if [[ -n "$http_pg_bin" ]]; then break; fi
    if [[ -x "$http_candidate/initdb" ]]; then http_pg_bin="$http_candidate"; break; fi
  done
fi
if [[ -z "$http_pg_bin" || ! -x "$http_pg_bin/initdb" ]]; then
  echo 'PostgreSQL server tools are required. Set BIST_POSTGRES_BIN to their bin directory.' >&2
  exit 1
fi
http_test_dir="$(mktemp -d /tmp/bist-http.XXXXXX)"
http_cleanup() {
  "$http_pg_bin/pg_ctl" -D "$http_test_dir/data" -m immediate -w stop >/dev/null 2>&1 || true
  rm -rf "$http_test_dir"
}
trap http_cleanup EXIT
"$http_pg_bin/initdb" -D "$http_test_dir/data" -A trust -U bist_test --no-locale --encoding=UTF8 > "$http_test_dir/init.log"
"$http_pg_bin/pg_ctl" -D "$http_test_dir/data" -l "$http_test_dir/server.log" -o "-k $http_test_dir -p 5432 -c listen_addresses=''" -w start >/dev/null
unset PGSERVICE PGSERVICEFILE PGHOSTADDR PGPASSWORD PGOPTIONS
export PGHOST="$http_test_dir" PGPORT=5432 PGUSER=bist_test PGDATABASE=postgres
export BIST_HTTP_FIXTURE_DIR="$http_test_dir" BIST_RELAY_PSQL="$http_pg_bin/psql"
mkdir -p build/tests build/module-cache
xcrun swiftc -whole-module-optimization -I Shared/Sources/CSQLite -module-cache-path "$PWD/build/module-cache" \
  Shared/Sources/BistSync/*.swift Sources/BistCore.swift Sources/LocalInbox.swift \
  Sources/NoteStore.swift Sources/BistSync.swift Sources/CloudKitSync.swift \
  Sources/SupabaseAuth.swift Sources/SupabaseAccount.swift Sources/SupabaseSync.swift \
  Tests/SupabaseHTTPIntegrationTests.swift -lsqlite3 -o build/tests/supabase-http-integration
python3 Tests/SupabaseHTTPFixture.py
