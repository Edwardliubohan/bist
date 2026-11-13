#!/usr/bin/env python3
"""Runs actual PostgREST/JWT authentication against a disposable relay schema."""
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import socket
import subprocess
import tarfile
import time
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = Path(os.environ['BIST_HTTP_FIXTURE_DIR'])
PSQL = [os.environ['BIST_RELAY_PSQL'], '-X', '-A', '-t', '-q', '-v', 'ON_ERROR_STOP=1',
        '--host', str(FIXTURE), '--port', '5432', '--username', 'bist_test', '--dbname', 'postgres']
VERSION = '16.5'
# Official release asset SHA256 digests published by PostgREST on GitHub.
ASSETS = {
    ('Darwin', 'arm64'): ('macos-aarch64', 'd8095cb439de0a3151036df542139e7afca5cebb109ce7f1bae52b3a97e9846a'),
    ('Darwin', 'x86_64'): ('macos-x86-64', 'dd4d346cd65dba4863ae02686fd09d2e34bbb6889e05d8ff7f1ac42ba0939515'),
    ('Linux', 'aarch64'): ('linux-static-aarch64', '96d75a34c7c095d5f97b87f88042f898192724350861328db9e1509e696ea057'),
    ('Linux', 'x86_64'): ('linux-static-x86-64', '5099e7ada38f9f6846cd87c14c5f158b7c165f1e9959665ad412e61f4dceba95'),
}


def postgrest_binary():
    supplied = os.environ.get('BIST_POSTGREST_BIN') or shutil.which('postgrest')
    if supplied:
        return str(Path(supplied).resolve())
    target, expected = ASSETS[(platform.system(), platform.machine())]
    directory = ROOT / 'build' / 'tools' / f'postgrest-v{VERSION}' / target
    binary = directory / 'postgrest'
    if binary.exists():
        return str(binary)
    directory.mkdir(parents=True, exist_ok=True)
    url = f'https://github.com/PostgREST/postgrest/releases/download/v{VERSION}/postgrest-v{VERSION}-{target}.tar.xz'
    temporary = directory / (uuid.uuid4().hex + '.tar.xz')
    try:
        with urllib.request.urlopen(url, timeout=45) as source, temporary.open('wb') as output:
            shutil.copyfileobj(source, output, length=1024 * 1024)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != expected:
            raise RuntimeError('Official PostgREST release archive digest mismatch')
        with tarfile.open(temporary) as archive:
            member = next(m for m in archive.getmembers() if m.isfile() and Path(m.name).name == 'postgrest')
            extracted = directory / (uuid.uuid4().hex + '.binary')
            extracted.write_bytes(archive.extractfile(member).read())
            extracted.chmod(0o755)
            extracted.replace(binary)
    finally:
        temporary.unlink(missing_ok=True)
    return str(binary)


def sql(statement):
    result = subprocess.run(PSQL, input=statement, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout.strip()


def encode(value):
    return base64.urlsafe_b64encode(json.dumps(value, separators=(',', ':')).encode()).rstrip(b'=')


def token(user, role='authenticated', expired=False, forged=False):
    header = encode({'alg': 'HS256', 'typ': 'JWT'})
    body = encode({'role': role, 'sub': user, 'aud': 'authenticated',
                   'iat': int(time.time()) - 3600, 'exp': int(time.time()) + (-60 if expired else 3600)})
    content = header + b'.' + body
    signature = hmac.new((SECRET + ('forged' if forged else '')).encode(), content, hashlib.sha256).digest()
    return (content + b'.' + base64.urlsafe_b64encode(signature).rstrip(b'=')).decode()


SECRET = 'bist-disposable-fixture-signing-key-2026-not-a-real-credential'
API_KEY = 'sb_publishable_bistHTTPFixture'
ALICE = '11111111-1111-4111-8111-111111111111'
BOB = '22222222-2222-4222-8222-222222222222'
sql("""
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN;
CREATE ROLE authenticator LOGIN NOINHERIT;
GRANT anon, authenticated TO authenticator;
CREATE SCHEMA auth;
CREATE TABLE auth.users(id uuid PRIMARY KEY);
INSERT INTO auth.users VALUES ('11111111-1111-4111-8111-111111111111'), ('22222222-2222-4222-8222-222222222222');
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
 SELECT coalesce(nullif(current_setting('request.jwt.claim.sub',true),''),
                 nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub')::uuid
$$;
GRANT USAGE ON SCHEMA public, auth TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role;
""")
sql((ROOT / 'supabase/migrations/202611130001_bist_sync.sql').read_text())
# This test-only pre-request check proves that the actual client carries the
# apikey header through its injected URL rewrite. It is not a Kong substitute
# or a claim that Supabase's managed gateway has been exercised.
sql(f"""
CREATE FUNCTION public.bist_fixture_header_check() RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF nullif(current_setting('request.headers',true),'')::jsonb->>'apikey' IS DISTINCT FROM '{API_KEY}' THEN
   RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Fixture apikey header missing';
 END IF;
 IF nullif(current_setting('request.headers',true),'')::jsonb->>'x-bist-fixture-timeout' = '1' THEN
   RAISE EXCEPTION USING ERRCODE='57014', MESSAGE='canceling statement due to statement timeout';
 END IF;
END;
$$;
""")
with socket.socket() as chooser:
    chooser.bind(('127.0.0.1', 0))
    port = chooser.getsockname()[1]
origin = f'http://127.0.0.1:{port}'
config = FIXTURE / 'postgrest.conf'
config.write_text(f'''db-uri = "host={FIXTURE} port=5432 dbname=postgres user=authenticator"
db-schemas = "public"
db-anon-role = "anon"
db-pool = 5
db-config = false
db-pre-request = "public.bist_fixture_header_check"
jwt-secret = "{SECRET}"
jwt-aud = "authenticated"
server-host = "127.0.0.1"
server-port = {port}
log-level = "error"
log-query = false
''')
config.chmod(0o600)
fixture_file = FIXTURE / 'http-fixture.json'
fixture_file.write_text(json.dumps({'origin': origin, 'apiKey': API_KEY, 'aliceID': ALICE, 'bobID': BOB,
                                   'aliceToken': token(ALICE), 'bobToken': token(BOB),
                                   'anonToken': token(ALICE, role='anon'), 'forgedToken': token(BOB, forged=True),
                                   'expiredToken': token(ALICE, expired=True)}))
fixture_file.chmod(0o600)
binary = postgrest_binary()
# PostgREST environment variables override its config file. Never inherit a
# user's hosted DB URI, public listener or JWT key into this private fixture.
service_env = {key: value for key, value in os.environ.items() if not key.startswith('PGRST_')}
if platform.system() == 'Darwin':
    # Official Mac releases link libpq at Homebrew's standalone formula path.
    # Use the selected isolated server toolchain's compatible libpq instead,
    # without requiring a second global Homebrew installation on CI.
    pg_config = str(Path(os.environ['BIST_RELAY_PSQL']).with_name('pg_config'))
    library_directory = subprocess.check_output([pg_config, '--libdir'], text=True).strip()
    service_env['DYLD_LIBRARY_PATH'] = library_directory
version = subprocess.check_output([binary, '--version'], text=True, env=service_env).strip()
print(f'HTTP fixture uses {version}', flush=True)
log_file = FIXTURE / 'postgrest.log'
with log_file.open('wb') as log:
    service = subprocess.Popen([binary, str(config)], stdout=log, stderr=log, env=service_env)
    try:
        def stop_on_signal(signum, frame):
            raise SystemExit(128 + signum)
        signal.signal(signal.SIGTERM, stop_on_signal)
        deadline = time.monotonic() + 15
        while True:
            if service.poll() is not None:
                raise RuntimeError('PostgREST failed to start\n' + log_file.read_text())
            try:
                request = urllib.request.Request(origin + '/', headers={'apikey': API_KEY})
                with urllib.request.urlopen(request, timeout=1) as response:
                    if response.status == 200:
                        break
            except (urllib.error.URLError, TimeoutError):
                if time.monotonic() >= deadline:
                    raise RuntimeError('PostgREST did not become ready\n' + log_file.read_text())
                time.sleep(0.05)
        env = dict(os.environ, BIST_SUPABASE_HTTP_FIXTURE=str(fixture_file))
        subprocess.run([str(ROOT / 'build/tests/supabase-http-integration')], env=env, check=True)
    finally:
        service.terminate()
        try:
            service.wait(timeout=5)
        except subprocess.TimeoutExpired:
            service.kill()
            service.wait()
