#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# This suite owns a new private Unix-socket-only cluster. It never connects to
# the user's normal Postgres service or a hosted Supabase project.
if [[ -n "${BIST_POSTGRES_BIN:-}" ]]; then
  relay_pg_bin="$BIST_POSTGRES_BIN"
elif command -v initdb >/dev/null 2>&1; then
  relay_pg_bin="$(dirname "$(command -v initdb)")"
else
  relay_pg_bin=""
  if command -v pg_config >/dev/null 2>&1; then
    relay_config_bin="$(pg_config --bindir)"
    if [[ -x "$relay_config_bin/initdb" ]]; then relay_pg_bin="$relay_config_bin"; fi
  fi
  for relay_candidate in /opt/homebrew/opt/postgresql@17/bin /opt/homebrew/opt/postgresql@15/bin /opt/homebrew/opt/postgresql@14/bin /usr/lib/postgresql/18/bin /usr/lib/postgresql/17/bin /usr/lib/postgresql/16/bin /usr/lib/postgresql/15/bin /usr/lib/postgresql/14/bin; do
    if [[ -n "$relay_pg_bin" ]]; then break; fi
    if [[ -x "$relay_candidate/initdb" ]]; then
      relay_pg_bin="$relay_candidate"
      break
    fi
  done
fi
if [[ -z "$relay_pg_bin" || ! -x "$relay_pg_bin/initdb" ]]; then
  echo 'PostgreSQL server tools are required. Set BIST_POSTGRES_BIN to their bin directory.' >&2
  exit 1
fi
relay_test_dir="$(mktemp -d /tmp/bist-relay.XXXXXX)"
relay_cleanup() {
  "$relay_pg_bin/pg_ctl" -D "$relay_test_dir/data" -m immediate -w stop >/dev/null 2>&1 || true
  rm -rf "$relay_test_dir"
}
trap relay_cleanup EXIT
"$relay_pg_bin/initdb" -D "$relay_test_dir/data" -A trust -U bist_test --no-locale --encoding=UTF8 > "$relay_test_dir/init.log"
"$relay_pg_bin/pg_ctl" -D "$relay_test_dir/data" -l "$relay_test_dir/server.log" -o "-k $relay_test_dir -p 5432 -c listen_addresses=''" -w start > /dev/null
export PGHOST="$relay_test_dir" PGPORT=5432 PGUSER=bist_test PGDATABASE=postgres
# A user's service file or PGHOSTADDR must never redirect this disposable suite
# to their real database. These changes affect only this script's environment.
unset PGSERVICE PGSERVICEFILE PGHOSTADDR PGPASSWORD PGOPTIONS
export BIST_RELAY_PSQL="$relay_pg_bin/psql"
python3 Tests/SupabaseRelayTests.py
