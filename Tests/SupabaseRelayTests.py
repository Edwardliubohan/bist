#!/usr/bin/env python3
"""Real PostgreSQL contract, authorization and concurrent-transaction probes."""
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

PSQL = [os.environ['BIST_RELAY_PSQL'], '-X', '-A', '-t', '-q', '-v', 'ON_ERROR_STOP=1',
        '--host', os.environ['PGHOST'], '--port', os.environ['PGPORT'],
        '--username', 'bist_test', '--dbname', 'postgres']
ALICE = '11111111-1111-4111-8111-111111111111'
BOB = '22222222-2222-4222-8222-222222222222'
checks = 0


def expect(value, message):
    global checks
    checks += 1
    if not value:
        raise AssertionError(message)


def sql(statement, user=None, role='authenticated', ok=True):
    prefix = '' if role is None else f'SET ROLE {role};\n'
    if user:
        prefix += f"SET request.jwt.claim.sub = '{user}';\n"
    result = subprocess.run(PSQL, input=prefix + statement, text=True, capture_output=True)
    if ok and result.returncode:
        raise AssertionError(result.stderr.strip())
    if not ok:
        expect(result.returncode != 0, 'request expected to fail')
        return result.stderr
    return result.stdout.strip()


def literal(value):
    return "'" + json.dumps(value, separators=(',', ':')).replace("'", "''") + "'::jsonb"


def stamp(counter=1, device='test-device'):
    return {'counter': counter, 'deviceID': device}


def field(value, counter=1, device='test-device'):
    data = json.dumps(value, separators=(',', ':')).encode()
    return {'value': base64.b64encode(data).decode(), 'stamp': stamp(counter, device), 'history': [], 'context': {}}


def event(text, counter=1, device='test-device'):
    record = {'id': 'note.main', 'kind': 'note', 'fields': {'text': field(text, counter, device)}}
    return wrap(record)


def wrap(record):
    data = json.dumps(record, sort_keys=True, separators=(',', ':')).encode()
    return {'event_id': hashlib.sha256(data).hexdigest(), 'record': record}


def push(events, user=ALICE):
    return json.loads(sql(f'SELECT public.bist_sync_push({literal(events)});', user))


def pull(after=0, limit=100, user=ALICE):
    return json.loads(sql(f'SELECT public.bist_sync_pull({after}, {limit});', user))


def rejected(events, user=ALICE):
    return sql(f'SELECT public.bist_sync_push({literal(events)});', user, ok=False)


sql("""
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN;
CREATE SCHEMA auth;
CREATE TABLE auth.users (id uuid PRIMARY KEY);
INSERT INTO auth.users VALUES ('11111111-1111-4111-8111-111111111111'), ('22222222-2222-4222-8222-222222222222');
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
GRANT USAGE ON SCHEMA auth TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role;
""", role=None)

migration = Path(os.environ.get('BIST_RELAY_MIGRATION', 'supabase/migrations/202611130001_bist_sync.sql'))
if migration.exists():
    sql(migration.read_text(), role=None)
expect(sql("SELECT to_regprocedure('public.bist_sync_push(jsonb)') IS NOT NULL;", role=None) == 't',
       'authenticated relay push RPC is not implemented')
expect(sql("SELECT to_regprocedure('public.bist_sync_pull(bigint,integer)') IS NOT NULL;", role=None) == 't',
       'authenticated relay pull RPC is not implemented')

empty = pull()
expect(empty['events'] == [] and empty['next_cursor'] == 0 and not empty['has_more'], 'empty feed contract')
server_id = str(uuid.UUID(empty['server_id']))

# Migration reruns preserve records and the instance identity.
first = event('First')
accepted = push([first])
expect(accepted == {'accepted': [first['event_id']], 'server_id': server_id}, 'push acknowledgments are exact event IDs')
sql(migration.read_text(), role=None)
expect(pull()['server_id'] == server_id, 'schema reapply must not reset server identity')
expect(len(pull()['events']) == 1, 'schema reapply must not remove data')
one = pull()['events'][0]
expect(one['record'] == first['record'] and one['event_id'] == first['event_id'], 'record is returned losslessly')
expect(one['sequence'] > 0, 'positive server sequence')
expect(pull(one['sequence'])['events'] == [], 'cursor excludes previously received events')
expect(pull(one['sequence'])['next_cursor'] == one['sequence'], 'empty pull retains cursor')

push([first])
expect(len(pull()['events']) == 1, 'lost-response retry is idempotent')
push([first, first])
expect(len(pull()['events']) == 1, 'duplicate event in one push is idempotent')
conflict = dict(first, record=event('Different body')['record'])
expect('BIST_EVENT_CONFLICT' in rejected([conflict]), 'event ID collision rejects a different body')
before = len(pull()['events'])
try:
    push([event('Must roll back'), conflict])
    raise AssertionError('mixed failed batch accepted')
except AssertionError as failure:
    expect('BIST_EVENT_CONFLICT' in str(failure), 'mixed batch fails for conflicting id')
expect(len(pull()['events']) == before, 'failed batch rolls back every inserted event')

# Tenant identity comes from the JWT, never a caller-supplied owner.
expect(pull(user=BOB)['events'] == [], 'second user cannot read first user')
push([first], user=BOB)
expect(len(pull(user=BOB)['events']) == 1, 'event deduplication is per tenant')
expect(len(pull()['events']) == before, 'second user cannot change first user feed')
for fn in ("SELECT public.bist_sync_pull();", f'SELECT public.bist_sync_push({literal([first])});'):
    expect('permission denied' in sql(fn, ALICE, role='anon', ok=False), 'anon cannot invoke authenticated RPC')
    expect('BIST_AUTH_REQUIRED' in sql(fn, role='authenticated', ok=False), 'missing subject is refused')
for table in ('events', 'instance'):
    for action in (f'SELECT * FROM bist_sync_private.{table};', f'DELETE FROM bist_sync_private.{table};'):
        expect('permission denied' in sql(action, ALICE, ok=False), 'clients cannot bypass relay through private tables')
for action in ("SELECT * FROM bist_sync_private.events_seq_seq;", "SELECT bist_sync_private.validate_record('{}');"):
    expect('permission denied' in sql(action, ALICE, ok=False), 'clients cannot mutate sequences or invoke private validators')
expect(sql("SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='bist_sync_private' AND c.relname IN ('events','instance') AND c.relrowsecurity;", role=None) == '2', 'private tables have RLS enabled')
sql('GRANT USAGE ON SCHEMA bist_sync_private TO authenticated; GRANT SELECT ON bist_sync_private.events TO authenticated;', role=None)
expect(sql('SELECT count(*) FROM bist_sync_private.events;', ALICE) == str(before), 'RLS still isolates Alice after a future accidental select grant')
expect(sql('SELECT count(*) FROM bist_sync_private.events;', BOB) == '1', 'RLS still isolates Bob after a future accidental select grant')
expect('permission denied' in sql("UPDATE bist_sync_private.events SET record='{}'::jsonb;", ALICE, ok=False), 'clients cannot rewrite immutable history')
sql('REVOKE ALL ON SCHEMA bist_sync_private FROM authenticated; REVOKE ALL ON bist_sync_private.events FROM authenticated;', role=None)

malformed = [None, {}, [dict(first, user_id=BOB)], [dict(first, event_id='x')],
             [dict(first, record=dict(first['record'], localSnapshot={}))],
             [wrap(dict(first['record'], kind='session'))],
             [wrap(dict(first['record'], id='note.other'))],
             [wrap(dict(first['record'], fields={'sourceURL': field('/private/path')}))],
             [wrap(dict(first['record'], fields={'text': {'value': 'bad%base64', 'stamp': stamp()}}))],
             [wrap(dict(first['record'], fields={'text': dict(field('bad'), stamp=stamp(0))}))],
             [wrap(dict(first['record'], fields={'text': dict(field('bad'), localSnapshot={})}))],
             [wrap(dict(first['record'], fields={'text': dict(field('bad'), context={'test-device': 1})}))]]
for bad in malformed:
    expect('BIST_INVALID_' in rejected(bad), 'malformed or nonportable payload is rejected')
for after, limit in ((-1, 1), (0, 0), (0, 101), (9223372036854775807, 1)):
    message = sql(f'SELECT public.bist_sync_pull({after}, {limit});', ALICE, ok=False)
    expect('BIST_INVALID_CURSOR' in message or 'BIST_CURSOR_AHEAD' in message, 'invalid cursor/page is rejected')
expect('BIST_INVALID_BATCH' in rejected([event(str(i), i + 2) for i in range(33)]), 'push event count is bounded')

# Tombstone/restoration provenance and concurrent field versions stay intact.
task_id = 'task.33333333-3333-4333-8333-333333333333'
tombstone = wrap({'id': task_id, 'kind': 'task', 'fields': {}, 'deletion': stamp(7), 'restoration': stamp(6)})
push([tombstone])
history = event('Latest', 10, 'new-device')
history['record']['fields']['text']['history'] = [{'value': field('Other')['value'], 'stamp': stamp(9, 'old-device')}]
history['record']['fields']['text']['context'] = {'prior-device': 4}
history = wrap(history['record'])
push([history])
events = {e['event_id']: e['record'] for e in pull()['events']}
expect(events[tombstone['event_id']] == tombstone['record'], 'deletion/restoration stamps preserved')
expect(events[history['event_id']] == history['record'], 'history and causal context preserved')
unicode_record = event('placeholder', 11)['record']
unicode_value = json.dumps("🙂 e\u0301\r\n \ufeff 'quote' \u0000", ensure_ascii=False).encode('utf8')
unicode_record['fields']['text']['value'] = base64.b64encode(unicode_value).decode()
unicode_event = wrap(unicode_record)
push([unicode_event])
expect(any(e['record'] == unicode_record for e in pull()['events']), 'UTF8, literal BOM, escaped NUL and line endings stay byte-exact')

# Pagination is stable across global sequence gaps introduced by other tenants.
for i in range(3):
    push([event(f'page-{i}', 20 + i)])
    push([event(f'bob-page-{i}', 20 + i)], user=BOB)
seen = []
cursor = 0
while True:
    page = pull(cursor, 2)
    expect(len(page['events']) <= 2, 'requested page count honored')
    seen += [e['event_id'] for e in page['events']]
    expect(page['next_cursor'] >= cursor, 'cursor monotonic')
    cursor = page['next_cursor']
    if not page['has_more']:
        break
expect(seen == [e['event_id'] for e in pull()['events']], 'pagination has no gaps or duplicates')

# A transaction that allocated a lower sequence must commit before a same-user
# writer or reader can advance past it. A different tenant must stay unblocked.
late = event('late-commit', 101)
next_event = event('next-commit', 102)
holder_sql = f"BEGIN; SET ROLE authenticated; SET request.jwt.claim.sub='{ALICE}'; SELECT public.bist_sync_push({literal([late])}); SELECT pg_sleep(2); COMMIT;"
holder = subprocess.Popen(PSQL, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
holder.stdin.write(holder_sql)
holder.stdin.close()
holder_ack = json.loads(holder.stdout.readline())
expect(holder_ack['accepted'] == [late['event_id']], 'holder allocated its uncommitted event')
writer_sql = f"SET ROLE authenticated; SET request.jwt.claim.sub='{ALICE}'; SELECT public.bist_sync_push({literal([next_event])});"
reader_sql = f"SET ROLE authenticated; SET request.jwt.claim.sub='{ALICE}'; SELECT public.bist_sync_pull(0,100);"
writer = subprocess.Popen(PSQL, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
reader = subprocess.Popen(PSQL, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
writer.stdin.write(writer_sql)
writer.stdin.close()
reader.stdin.write(reader_sql)
reader.stdin.close()
time.sleep(0.15)
expect(writer.poll() is None, 'same-user writer waits for lower-sequence transaction')
expect(reader.poll() is None, 'same-user pull waits for lower-sequence transaction')
other = subprocess.run(PSQL, input=f"SET ROLE authenticated; SET request.jwt.claim.sub='{BOB}'; SELECT public.bist_sync_push({literal([event('independent tenant', 200)])});", text=True, capture_output=True, timeout=1)
expect(other.returncode == 0 and holder.poll() is None, 'different tenant is not blocked by another tenant lock')
expect(holder.wait(timeout=5) == 0, 'holder commits successfully')
expect(writer.wait(timeout=5) == 0 and reader.wait(timeout=5) == 0, 'waiting requests complete')
observed = json.loads(reader.stdout.read())
observed_ids = {e['event_id'] for e in observed['events']}
expect(late['event_id'] in observed_ids, 'pull includes lower event after waiting for commit')
observed_ids |= {e['event_id'] for e in pull(observed['next_cursor'])['events']}
expect(next_event['event_id'] in observed_ids, 'follow-up pull cannot skip the next committed event')
full = {e['event_id']: e['sequence'] for e in pull()['events']}
expect(full[late['event_id']] < full[next_event['event_id']], 'same-user identity allocation follows commit order')

# Real UTF8 response sizes, rather than compressed pg_column_size, govern pages.
# Repetitive note text compresses extremely well in Postgres and would make a
# storage-size-based budget accidentally return arbitrarily large responses.
CAROL = '33333333-3333-4333-8333-333333333333'
sql(f"INSERT INTO auth.users VALUES ('{CAROL}');", role=None)
max_value_text = 'x' * (16 * 1024 * 1024 - 2)
large_one = event(max_value_text, 300)
large_two = event('y' * len(max_value_text), 301)
push([large_one, large_two], CAROL)
page = pull(user=CAROL)
expect(len(page['events']) == 1 and page['has_more'], 'two22MiB wire events split despite compact physical storage')
expect(page['events'][0]['event_id'] == large_one['event_id'], 'first maximum-size value round-trips')
page_two = pull(page['next_cursor'], user=CAROL)
expect(len(page_two['events']) == 1 and not page_two['has_more'], 'large second page completes')
expect(page_two['events'][0]['record'] == large_two['record'], 'second large note remains byte-exact')
expect(len(json.dumps(page, ensure_ascii=False).encode()) <= 32 * 1024 * 1024, 'ordinary pull stays within32MiB including envelope')
expect('BIST_INVALID_RECORD' in rejected([event('z' * (16 * 1024 * 1024 - 1), 302)], CAROL), 'decoded field limit rejects16MiB plus one byte')
large_history = event(max_value_text, 400, 'latest')
large_history['record']['fields']['text']['history'] = [{'value': large_two['record']['fields']['text']['value'], 'stamp': stamp(399, 'concurrent')}]
large_history = wrap(large_history['record'])
push([large_history], CAROL)
wide_page = pull(page_two['next_cursor'], user=CAROL)
expect(len(wide_page['events']) == 1, 'first accepted event is always returned even above32MiB')
wide_bytes = len(json.dumps(wide_page, ensure_ascii=False).encode())
expect(32 * 1024 * 1024 < wide_bytes < 48 * 1024 * 1024, 'large concurrent note stays below maximum wire event allowance')
expect(wide_page['events'][0]['record'] == large_history['record'], 'large concurrent note versions survive transport')
large_value_cte = """WITH v AS (SELECT replace(encode(convert_to('"' || repeat('k',12582910) || '"','UTF8'),'base64'), E'\\n','') AS data),
r AS (SELECT jsonb_build_object('id','note.main','kind','note','fields',jsonb_build_object('text',jsonb_build_object(
'value',data,'stamp',jsonb_build_object('counter',3,'deviceID','wire-limit'),'context','{}'::jsonb,'history','[]'::jsonb))) AS record, data FROM v)
"""
oversized_event = large_value_cte + """SELECT public.bist_sync_push(jsonb_build_array(jsonb_build_object('event_id',repeat('a',64),'record',
jsonb_set(record,'{fields,text,history}',jsonb_build_array(
jsonb_build_object('value',data,'stamp',jsonb_build_object('counter',1,'deviceID','earlier-one')),
jsonb_build_object('value',data,'stamp',jsonb_build_object('counter',2,'deviceID','earlier-two'))))))) FROM r;"""
expect('BIST_INVALID_EVENT' in sql(oversized_event, CAROL, ok=False), '48MiB event bound rejects valid but excessively large history')
oversized_batch = large_value_cte + """SELECT public.bist_sync_push((SELECT jsonb_agg(jsonb_build_object('event_id',repeat(i::text,64),'record',record)) FROM generate_series(1,5) i)) FROM r;"""
expect('BIST_INVALID_BATCH' in sql(oversized_batch, CAROL, ok=False), '64MiB push bound rejects a batch of otherwise valid events')
expect(pull(wide_page['next_cursor'], user=CAROL)['events'] == [], 'size rejection leaves the feed unchanged')
sql("UPDATE bist_sync_private.instance SET server_id=gen_random_uuid();", role=None)
expect(pull()['server_id'] != server_id, 'server reset identity is visible without silently resetting feed cursors')

print(f'{checks} Supabase relay checks passed')
