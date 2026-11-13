# Bist Supabase relay

This relay lets the native Mac and iPhone builds exchange their existing portable task, tag and note revisions over HTTPS. It does not require Apple iCloud capabilities. The app's authentication and sync controls remain responsible for choosing a project and account before uploading local data.

## Create a private project

1. Create a Supabase project in a Free organization. Keep billing on the Free plan.
2. Apply [the migration](migrations/202611130001_bist_sync.sql) in the project's SQL editor. Reapplying it preserves the feed and its server identity.
3. In Auth, configure email sign-in to send a code. The Magic Link and Confirm Signup email templates must include `{{ .Token }}` when Bist uses a numeric code instead of a link. Supabase's built-in mail service is restricted and rate limited. Verify delivery to the intended account before depending on it.
4. Configure Bist with the HTTPS project URL and its publishable key (or legacy `anon` key). Never put a project management token, database password, secret key or `service_role` key into an app or its build configuration.
5. Use the same authenticated email account on both devices. For a private personal project, create the intended owner account and disable new user signups once it works. Keep anonymous sign-in off.

The SQL creates tables in an unexposed private schema. Only the two authenticated RPCs in `public` are callable by app clients. Their caller identity comes from Supabase Auth, and clients cannot supply a different owner or write directly to the immutable feed. Row Level Security also restricts reads to their owner if table access is granted in a later migration.

## Protocol

`POST /rest/v1/rpc/bist_sync_push` accepts this body.

```json
{"p_events":[{"event_id":"64 lowercase hex characters","record":{"id":"note.main","kind":"note","fields":{}}}]}
```

The example illustrates the envelope only. A live note needs a valid `text` field containing the complete `ReplicaField` value. The server validates identities, portable field names, revisions, base64 and encoded JSON values. Task and tag tombstones preserve their deletion and restoration stamps.

The client computes `event_id` as SHA256 of its sorted-key JSON encoding of the `ReplicaRecord`. The server checks the identifier's shape and compares duplicate records as JSON. It does not hash PostgreSQL's differently formatted `jsonb::text`. A repeated event is acknowledged without creating another row. Reusing its identifier with different contents rejects and rolls back the entire push.

```json
{"accepted":["event hash"],"server_id":"instance UUID"}
```

`POST /rest/v1/rpc/bist_sync_pull` accepts this body.

```json
{"p_after":0,"p_limit":100}
```

Its response carries the portable revisions in ascending server sequence order.

```json
{"events":[{"sequence":1,"event_id":"event hash","record":{}}],"next_cursor":1,"has_more":false,"server_id":"instance UUID"}
```

Each user has a transaction advisory lock shared by push and pull. Writers acquire it before allocating a sequence. Readers wait for an earlier writer to commit, so a late lower-sequence transaction cannot be skipped. Different users have different locks. The RPCs use an empty `search_path` and explicit owner filters because their definer privileges allow access to tables that app users cannot write.

Persist the returned cursor and instance identity in the same local transaction that validates and merges the records. Fetch before uploading. Acknowledge only exact uploaded local bodies after a complete successful response, and only while the original account and transport generation are still active.

## Bounds and recovery

- Push accepts 1 to 32 events and at most 64 MiB of UTF8 JSON. Each event may use at most 48 MiB. Each decoded field or history value may use at most 16 MiB, matching local replica validation.
- Pull accepts 1 to 100 events. Pages target 32 MiB of actual UTF8 JSON plus a small envelope. A single accepted event can exceed that page target, so the first event is always returned and remains below 48 MiB plus its small sequence envelope. No page estimates its size from PostgreSQL's compressed storage.
- Native replica transfers allow up to 90 seconds without progress and up to 30 minutes in total. Authentication keeps its shorter 30-second idle and 45-second total limits. A timed-out pull retries the same cursor with fewer events, down to one. A timed-out push splits its original immutable events into smaller batches, down to one. Both share a two-minute retry window, with each attempt's idle timeout capped to its remaining time. A progressing request can finish after that window, but cannot start another retry. A one-event timeout remains pending for a later sync. Disabling sync or leaving the foreground cancels active requests.
- Hosted Supabase applies a separate database statement timeout, documented as 8 seconds for the authenticated role. The client also shrinks pages and splits batches when PostgREST returns SQLSTATE `57014`. This migration does not change server timeouts. An event that still times out remains queued. Inspect the project logs before retrying. See [Supabase database timeouts](https://supabase.com/docs/guides/database/postgres/timeouts).
- `BIST_AUTH_REQUIRED` means a missing authenticated user.
- `BIST_INVALID_BATCH`, `BIST_INVALID_EVENT`, `BIST_INVALID_RECORD` and `BIST_INVALID_CURSOR` reject malformed requests without accepting partial writes.
- `BIST_EVENT_CONFLICT` means an event identifier was reused with different contents. Keep the pending local changes and surface the error.
- `BIST_CURSOR_AHEAD` means the supplied cursor exceeds the authenticated user's current feed head. Pause for explicit recovery. Do not quietly clear the cursor and report success.
- A changed `server_id` signals a recreated server instance. Keep local data and require explicit recovery before uploading retained records to the new instance.

The relay retains full revisions and does not compact them. Large notes edited frequently can consume the Free plan's database and transfer quotas. Debounce uploads, monitor usage, and retain local pending changes when Supabase pauses the project or rejects a request. This schema never upgrades billing or discards older revisions to fit a quota. Native apps installed with Apple's free Personal Team still need signing refreshed separately.

Brief inactive phases, such as opening Control Center, keep an existing phone transfer running. Actual backgrounding cancels it. Returning to the app starts a fresh exchange, including when the old cancellation is still finishing.

## Test locally

Install PostgreSQL server tools, then run from the repository root.

```sh
./scripts/test-supabase-relay.sh
```

Set `BIST_POSTGRES_BIN` to the directory containing `initdb`, `pg_ctl` and `psql` if they are not found automatically. The script creates a fresh private cluster in `/tmp`, listens only on its own Unix socket, uses test-only Auth roles and users, then removes the cluster. It never connects to an existing local database or a hosted project.

The suite exercises real SQL authorization, idempotency, atomic rollback, record validation, pagination, large note values and concurrent transactions. A stand-in for Supabase's `auth.uid()` supplies the same JWT subject contract. It does not prove live email delivery, gateway configuration or a device round trip.

For the complete native client through a real HTTP service, run this additional lane on macOS.

```sh
./scripts/test-supabase-http.sh
```

It builds the actual `SupabaseRelayClient` and `SupabaseReplicaTransport`, starts real PostgREST with a separate isolated PostgreSQL cluster, and signs disposable JWTs for two fixture users. It covers offline native edits, concurrent note recovery, durable relaunch, deletion against a stale edit, lost-response deduplication, an edit during acknowledgment, account isolation, forged and expired tokens, anonymous denial, atomic rejection and real pagination. A test-only sender rewrites `https://project.test/rest/v1` to the localhost service while preserving the request method, headers and body. A one-shot fixture header also makes PostgreSQL raise query cancellation, testing its real PostgREST error response and smaller-request recovery. Neither HTTP routing nor SQL responses are mocked. This injected cancellation does not measure hosted query performance.

If PostgREST is absent, the lane downloads an official PostgREST 16.5 release into the ignored `build/tools` directory and verifies its pinned GitHub release SHA256 before extracting the binary. Set `BIST_POSTGREST_BIN` to use an already installed binary. On macOS, it uses the selected PostgreSQL toolchain's libpq library. The service listens only on `127.0.0.1` and is stopped when the fixture exits. Inherited PostgreSQL connection overrides and `PGRST_` settings cannot redirect it to another database or listener.

This lane proves PostgREST routing, JWT verification, role switching and the shipping Swift serialization against the migration. Its test-only API-key header check proves the client sends that header. Supabase's hosted gateway, GoTrue email authentication, TLS infrastructure and the physical devices remain separate acceptance checks.

Primary references are [Supabase function security](https://supabase.com/docs/guides/database/functions), [Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security), [API keys](https://supabase.com/docs/guides/getting-started/api-keys) and [Free plan limits](https://supabase.com/pricing).
