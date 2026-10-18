#!/usr/bin/env python3
"""Isolated PostgreSQL concurrency/regression verification; never connects to project DB.
Requires Docker and an already-pulled Supabase PostgreSQL image (override with
--image). Uses a fresh container with no host ports or mounted project data.
Runs all migrations as non-superuser postgres, then SQL tests and concurrency
checks. Synthetic Auth schema is sufficient for these database-only tests;
this does not test Supabase Auth or the Express integration.
The disposable container is removed in finally, including on test failure.
Usage: python3 supabase/tests/location_assignment_concurrency.py
"""
import argparse
import pathlib
import subprocess
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--image', default='public.ecr.aws/supabase/postgres:17.11.0.004')
args = p.parse_args()
name = 'operations-hub-write-test-' + uuid.uuid4().hex[:10]
base = ['docker', 'exec', '-i', name, 'psql', '-h', '/tmp', '-U', 'bootstrap',
        '-d', 'postgres', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1']
sessions = []
started = False

def sql(query, check=True):
    r = subprocess.run(base, input=query, text=True, capture_output=True, timeout=60)
    if check and r.returncode:
        raise RuntimeError(r.stderr + '\n' + r.stdout[-2000:])
    return r

def actor(who):
    return f"SELECT set_config('app.user_id','{ids[who]}',true);"

def set_assignment(role='employee'):
    return ("SELECT identity_access.set_location_assignment("
            f"'{ids['target']}','{ids['location']}',"
            f"(SELECT id FROM public.roles WHERE key='{role}'),gen_random_uuid());")

def lock_org():
    return ("SELECT pg_advisory_xact_lock(hashtextextended("
            f"'operations-hub:identity:{ids['org']}',0));")

def open_a(body):
    proc = subprocess.Popen(base, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, bufsize=1)
    sessions.append(proc)
    proc.stdin.write('BEGIN;\n\\o /dev/null\n' + body + '\n\\o\n\\echo READY\n')
    proc.stdin.flush()
    # Bound readline using select so an SQL error cannot hang the harness.
    import select
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        ready, _, _ = select.select([proc.stdout], [], [], 0.2)
        if ready:
            line = proc.stdout.readline().strip()
            if line == 'READY':
                return proc
        if proc.poll() is not None:
            raise RuntimeError(proc.stderr.read())
    raise RuntimeError('Lock-holder session did not become ready')

def competing(body, appname):
    proc = subprocess.Popen(base, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True)
    sessions.append(proc)
    proc.stdin.write(f"SET application_name='{appname}';\nBEGIN;\n" + body + '\nCOMMIT;\n')
    proc.stdin.close()
    proc.stdin = None
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        waiting = sql("SELECT count(*) FROM pg_stat_activity WHERE "
                      f"application_name='{appname}' AND wait_event='advisory';").stdout.strip()
        if waiting == '1':
            return proc
        if proc.poll() is not None:
            raise RuntimeError('Expected advisory-lock wait: ' + proc.stderr.read())
        time.sleep(0.05)
    raise RuntimeError('Contender did not wait on advisory lock')

def finish_a(proc):
    proc.stdin.write('COMMIT;\n\\q\n')
    proc.stdin.flush()
    proc.stdin.close()
    proc.stdin = None
    out, err = proc.communicate(timeout=15)
    if proc.returncode:
        raise RuntimeError(err + out)

try:
    # No image download, external network, published ports or host bind mounts.
    subprocess.run(['docker', 'run', '--pull=never', '--rm', '-d', '--network=none',
                    '--name', name, '--user', 'postgres', '--entrypoint', '/bin/bash',
                    args.image, '-c',
                    'initdb -D /tmp/write-test-pg -U bootstrap -A trust >/tmp/init.log && '
                    'exec postgres -D /tmp/write-test-pg -k /tmp -c listen_addresses='],
                   check=True, capture_output=True, text=True, timeout=30)
    started = True
    for _ in range(100):
        if sql('SELECT 1;', check=False).returncode == 0:
            break
        time.sleep(0.1)
    else:
        raise RuntimeError('Disposable PostgreSQL did not start')

    sql("""CREATE ROLE postgres LOGIN NOSUPERUSER CREATEDB CREATEROLE REPLICATION BYPASSRLS;
    CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN;
    CREATE ROLE service_role NOLOGIN;
    ALTER DATABASE postgres OWNER TO postgres;
    ALTER SCHEMA public OWNER TO postgres;
    CREATE SCHEMA auth AUTHORIZATION postgres;
    SET ROLE postgres;
    CREATE TABLE auth.users(id uuid PRIMARY KEY);
    RESET ROLE;
    """)
    for migration in sorted((ROOT / 'supabase/migrations').glob('*.sql')):
        command = base.copy()
        command[command.index('bootstrap')] = 'postgres'
        r = subprocess.run(command, input='BEGIN;\n' + migration.read_text() + '\nCOMMIT;',
                           text=True, capture_output=True, timeout=60)
        if r.returncode:
            raise RuntimeError(migration.name + ': ' + r.stderr)
    print('PASS: all migrations apply as non-superuser postgres', flush=True)
    for test in sorted((ROOT / 'supabase/tests').glob('*.sql')):
        # RESET ROLE inside tests must return to postgres, not bootstrap.
        command = base.copy()
        command[command.index('bootstrap')] = 'postgres'
        r = subprocess.run(command, input=test.read_text(), text=True,
                           capture_output=True, timeout=60)
        if r.returncode:
            raise RuntimeError(test.name + ': ' + r.stderr + r.stdout[-2000:])
        print('PASS: ' + test.name, flush=True)

    ids = {k: str(uuid.uuid4()) for k in ['org', 'brand', 'location', 'admin', 'manager', 'target']}
    sql(f"""INSERT INTO public.organizations(id,name) VALUES ('{ids['org']}','Concurrency');
    INSERT INTO public.brands(id,organization_id,name,slug)
      VALUES ('{ids['brand']}','{ids['org']}','Concurrency','concurrency');
    INSERT INTO public.locations(id,brand_id,name,timezone)
      VALUES ('{ids['location']}','{ids['brand']}','Concurrency','UTC');
    INSERT INTO auth.users(id) VALUES ('{ids['admin']}'),('{ids['manager']}'),('{ids['target']}');
    INSERT INTO public.users(id,organization_id,email,full_name)
      SELECT id,'{ids['org']}',id::text||'@example.invalid','Concurrency' FROM auth.users;
    INSERT INTO public.user_roles(user_id,organization_id,role_id,role_scope)
      SELECT '{ids['admin']}','{ids['org']}',id,scope FROM public.roles WHERE key='org_admin';
    INSERT INTO public.user_locations(user_id,organization_id,brand_id,location_id,role_id)
      SELECT '{ids['manager']}','{ids['org']}','{ids['brand']}','{ids['location']}',id
      FROM public.roles WHERE key='location_manager';
    """)

    # Two simultaneous grants: second waits and sees the committed first grant.
    a = open_a('SET LOCAL ROLE operations_hub_runtime;\n' + actor('admin') + set_assignment())
    b = competing('SET LOCAL ROLE operations_hub_runtime;\n' + actor('admin') + set_assignment(), 'assignment-second-grant')
    finish_a(a)
    out, err = b.communicate(timeout=15)
    assert b.returncode == 0 and 'unchanged' in out, (out, err)
    assert sql(f"SELECT count(*) FROM identity_access.assignment_audit_log WHERE target_user_id='{ids['target']}';").stdout.strip() == '1'
    print('PASS: concurrent duplicate grants serialize; one assignment/audit event', flush=True)

    # Revoke authority in A; manager in B must recheck it after waiting.
    sql(f"DELETE FROM public.user_locations WHERE user_id='{ids['target']}';")
    a = open_a('SET LOCAL ROLE operations_hub_runtime;\n' + actor('admin') +
               "SELECT identity_access.revoke_location_assignment("
               f"'{ids['manager']}','{ids['location']}',gen_random_uuid());")
    b = competing('SET LOCAL ROLE operations_hub_runtime;\n' + actor('manager') + set_assignment(), 'assignment-revoked-manager')
    finish_a(a)
    out, err = b.communicate(timeout=15)
    assert b.returncode != 0 and 'Assignment change is not authorized' in err, (out, err)
    assert sql(f"SELECT count(*) FROM public.user_locations WHERE user_id='{ids['target']}';").stdout.strip() == '0'
    print('PASS: waiting writer rechecks revoked management authority', flush=True)

    # Simulate a future deactivation writer following the same lock convention.
    a = open_a(lock_org() + f"UPDATE public.users SET is_active=false WHERE id='{ids['admin']}';")
    b = competing('SET LOCAL ROLE operations_hub_runtime;\n' + actor('admin') + set_assignment(), 'assignment-deactivated-admin')
    finish_a(a)
    out, err = b.communicate(timeout=15)
    assert b.returncode != 0 and 'Caller identity changed while waiting' in err, (out, err)
    print('PASS: waiting writer rejects caller deactivation', flush=True)

    sql(f"UPDATE public.users SET is_active=true WHERE id='{ids['admin']}';")
    for isolation in ['REPEATABLE READ', 'SERIALIZABLE']:
        r = sql(f'BEGIN ISOLATION LEVEL {isolation}; SET LOCAL ROLE operations_hub_runtime;'
                + actor('admin') + set_assignment(), check=False)
        assert r.returncode != 0 and 'require READ COMMITTED' in r.stderr, r.stderr
    print('PASS: unsupported isolation levels rejected', flush=True)
finally:
    for proc in sessions:
        if proc.poll() is None:
            proc.kill()
        proc.communicate(timeout=5)
    if started:
        subprocess.run(['docker', 'rm', '-f', name], check=True, capture_output=True, timeout=30)
        print('Disposable database removed; project database untouched.', flush=True)
