-- Run this entire file against local Supabase PostgreSQL 17+ as postgres,
-- after migrations 1-5. The runtime now has SELECT on locations only;
-- other application tables and all writes remain inaccessible.
-- Use one connection for the entire file so identity cleanup is meaningful.
-- CLI: psql <local-connection> -X -v ON_ERROR_STOP=1 -f <this-file>
-- All fixtures and the future-table probe are rolled back. The COMMIT test
-- commits no application data and removes its test membership before COMMIT.
-- If execution fails, issue ROLLBACK before retrying. Do not continue past errors.

BEGIN;

-- Refuse to change an existing session identity or SET-capable membership.
DO $$
BEGIN
    IF current_user <> 'postgres' THEN
        RAISE EXCEPTION 'Test setup requires postgres';
    END IF;
    IF NULLIF(current_setting('app.user_id', true), '') IS NOT NULL THEN
        RAISE EXCEPTION 'Test setup requires no existing session identity';
    END IF;
    IF pg_has_role('postgres', 'operations_hub_runtime', 'SET') THEN
        RAISE EXCEPTION 'Test setup expects no existing runtime SET membership';
    END IF;
END;
$$;

CREATE TEMP TABLE identity_test_results (
    test_name text PRIMARY KEY,
    executed_as text NOT NULL,
    result text NOT NULL
);

-- Assertions fail on both false and NULL; absent catalog rows cannot pass.
CREATE FUNCTION pg_temp.record_check(condition boolean, label text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF condition IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL: %', label;
    END IF;
    INSERT INTO pg_temp.identity_test_results
    VALUES (label, current_user, 'PASS');
END;
$$;

-- Independent expected matrix from docs/db-design.md, not derived from the
-- migration's inserts. EXCEPT in BOTH directions detects missing and extra pairs.
CREATE TEMP TABLE expected_identity_catalog (
    role_key text PRIMARY KEY,
    role_scope text NOT NULL,
    permissions text[] NOT NULL
);

INSERT INTO expected_identity_catalog VALUES
('org_admin', 'organization', ARRAY[
    'locations.read', 'users.read', 'users.invite', 'users.deactivate',
    'role_assignments.read', 'role_assignments.manage', 'tasks.manage',
    'task_instances.read', 'reports.read'
]),
('brand_admin', 'brand', ARRAY[
    'locations.read', 'users.read', 'users.invite',
    'role_assignments.read', 'role_assignments.manage', 'tasks.manage',
    'task_instances.read', 'reports.read'
]),
('location_manager', 'location', ARRAY[
    'locations.read', 'users.read', 'users.invite',
    'role_assignments.read', 'role_assignments.manage', 'tasks.manage',
    'task_instances.read', 'task_instances.complete',
    'task_instances.reopen', 'reports.read'
]),
('employee', 'location', ARRAY[
    'locations.read', 'users.read', 'role_assignments.read',
    'task_instances.read', 'task_instances.complete'
]);

DO $$
BEGIN
    PERFORM pg_temp.record_check(
        NOT EXISTS (
            SELECT 1 FROM pg_temp.expected_identity_catalog e
            FULL JOIN public.roles r ON r.key = e.role_key
            WHERE r.key IS NULL OR e.role_key IS NULL
               OR r.scope IS DISTINCT FROM e.role_scope
        ), 'Catalog: exact four roles and scopes'
    );

    PERFORM pg_temp.record_check(
        NOT EXISTS (
            WITH expected AS (
                SELECT DISTINCT unnest(permissions) AS key
                FROM pg_temp.expected_identity_catalog
            )
            SELECT 1 FROM expected e
            FULL JOIN public.permissions p ON p.key = e.key
            WHERE e.key IS NULL OR p.key IS NULL
        ), 'Catalog: exact eleven permission keys'
    );

    PERFORM pg_temp.record_check(
        (SELECT count(*) = 32 FROM public.role_permissions)
        AND NOT EXISTS (
            WITH expected AS (
                SELECT role_key, unnest(permissions) AS permission_key
                FROM pg_temp.expected_identity_catalog
            ), actual AS (
                SELECT r.key AS role_key, p.key AS permission_key
                FROM public.role_permissions rp
                JOIN public.roles r ON r.id = rp.role_id
                JOIN public.permissions p ON p.id = rp.permission_id
            )
            (SELECT * FROM expected EXCEPT SELECT * FROM actual)
            UNION ALL
            (SELECT * FROM actual EXCEPT SELECT * FROM expected)
        ), 'Catalog: exact 32 role-permission pairs'
    );

    PERFORM pg_temp.record_check(
        EXISTS (
            SELECT 1 FROM pg_catalog.pg_roles
            WHERE rolname = 'operations_hub_runtime'
              AND NOT rolsuper AND NOT rolbypassrls AND NOT rolcanlogin
              AND NOT rolcreatedb AND NOT rolcreaterole
              AND NOT rolreplication AND NOT rolinherit
        ), 'Runtime: all restricted attributes'
    );

    PERFORM pg_temp.record_check(
        EXISTS (
            SELECT 1 FROM pg_catalog.pg_roles
            WHERE rolname = 'operations_hub_auth_reader'
              AND rolbypassrls
              AND NOT rolsuper AND NOT rolcanlogin AND NOT rolcreatedb
              AND NOT rolcreaterole AND NOT rolreplication AND NOT rolinherit
        ), 'Reader: only BYPASSRLS is enabled'
    );

    PERFORM pg_temp.record_check(
        NOT EXISTS (
            SELECT 1 FROM pg_catalog.pg_auth_members
            WHERE member = 'operations_hub_runtime'::regrole
        )
        AND NOT pg_has_role(
            'operations_hub_runtime', 'operations_hub_auth_reader', 'MEMBER'
        )
        AND NOT pg_has_role(
            'operations_hub_runtime', 'operations_hub_auth_reader', 'SET'
        ), 'Runtime: no parent memberships or helper-role access'
    );

    PERFORM pg_temp.record_check(
        NOT pg_has_role('postgres', 'operations_hub_auth_reader', 'SET'),
        'Migration: helper SET permission was removed'
    );

    PERFORM pg_temp.record_check(
        NOT EXISTS (
            SELECT 1 FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'public'
              AND c.relowner IN (
                  'operations_hub_runtime'::regrole,
                  'operations_hub_auth_reader'::regrole
              )
        ), 'Runtime and reader: no ownership of public relations'
    );

    PERFORM pg_temp.record_check(
        EXISTS (
            SELECT 1 FROM pg_catalog.pg_proc
            WHERE oid = 'identity_access.current_actor_id()'::regprocedure
              AND NOT prosecdef AND provolatile = 's'
              AND proowner = 'postgres'::regrole
              AND proconfig @> ARRAY['search_path=""']
        ), 'Actor helper: owner, invoker, STABLE, fixed search path'
    );

    PERFORM pg_temp.record_check(
        EXISTS (
            SELECT 1 FROM pg_catalog.pg_proc
            WHERE oid = 'identity_access.current_active_user_id()'::regprocedure
              AND prosecdef AND provolatile = 's'
              AND proowner = 'operations_hub_auth_reader'::regrole
              AND proconfig @> ARRAY['search_path=""']
        ), 'Active-user helper: owner, definer, STABLE, fixed search path'
    );
END;
$$;

-- Check effective privileges (including PUBLIC and inherited grants).
-- Scope checks to our nine tables, not unrelated future public tables.
DO $$
DECLARE
    browser_role text;
    function_name text;
    table_name text;
    column_name text;
BEGIN
    FOREACH browser_role IN ARRAY ARRAY['anon', 'authenticated'] LOOP
        PERFORM pg_temp.record_check(
            NOT has_schema_privilege(browser_role, 'identity_access', 'USAGE,CREATE'),
            browser_role || ': no helper schema privileges'
        );

        FOREACH function_name IN ARRAY ARRAY[
            'identity_access.current_actor_id()',
            'identity_access.current_active_user_id()'
        ] LOOP
            PERFORM pg_temp.record_check(
                NOT has_function_privilege(browser_role, function_name, 'EXECUTE'),
                browser_role || ': cannot execute ' || function_name
            );
        END LOOP;

        FOREACH table_name IN ARRAY ARRAY[
            'organizations', 'users', 'brands', 'locations', 'roles',
            'permissions', 'role_permissions', 'user_roles', 'user_locations'
        ] LOOP
            PERFORM pg_temp.record_check(
                NOT has_table_privilege(
                    browser_role, format('public.%I', table_name),
                    'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'
                )
                AND NOT has_any_column_privilege(
                    browser_role, format('public.%I', table_name),
                    'SELECT,INSERT,UPDATE,REFERENCES'
                ), browser_role || ': no privileges on ' || table_name
            );
        END LOOP;
    END LOOP;

    FOREACH function_name IN ARRAY ARRAY[
        'identity_access.current_actor_id()',
        'identity_access.current_active_user_id()'
    ] LOOP
        PERFORM pg_temp.record_check(
            has_function_privilege('operations_hub_runtime', function_name, 'EXECUTE'),
            'Runtime: can execute ' || function_name
        );
    END LOOP;

    PERFORM pg_temp.record_check(
        has_schema_privilege('operations_hub_runtime', 'identity_access', 'USAGE')
        AND NOT has_schema_privilege('operations_hub_runtime', 'identity_access', 'CREATE')
        AND NOT has_schema_privilege('operations_hub_auth_reader', 'identity_access', 'CREATE'),
        'Helper schema: runtime USAGE only; temporary reader CREATE removed'
    );

    -- Location reads are intentional now; all other tables remain inaccessible.
    PERFORM pg_temp.record_check(
        has_table_privilege('operations_hub_runtime', 'public.locations', 'SELECT')
        AND NOT has_table_privilege(
            'operations_hub_runtime', 'public.locations',
            'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'
        )
        AND NOT has_any_column_privilege(
            'operations_hub_runtime', 'public.locations', 'INSERT,UPDATE,REFERENCES'
        ), 'Runtime: locations SELECT only, no write privileges'
    );
    FOREACH table_name IN ARRAY ARRAY[
        'organizations', 'users', 'brands', 'roles',
        'permissions', 'role_permissions', 'user_roles', 'user_locations'
    ] LOOP
        PERFORM pg_temp.record_check(
            NOT has_table_privilege(
                'operations_hub_runtime', format('public.%I', table_name),
                'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'
            )
            AND NOT has_any_column_privilege(
                'operations_hub_runtime', format('public.%I', table_name),
                'SELECT,INSERT,UPDATE,REFERENCES'
            ), 'Foundation runtime: no direct privileges on ' || table_name
        );
    END LOOP;

    -- Reader may select only id and is_active from users, with no writes.
    FOR column_name IN
        SELECT attname FROM pg_catalog.pg_attribute
        WHERE attrelid = 'public.users'::regclass
          AND attnum > 0 AND NOT attisdropped
    LOOP
        PERFORM pg_temp.record_check(
            has_column_privilege(
                'operations_hub_auth_reader', 'public.users', column_name, 'SELECT'
            ) = (column_name IN ('id', 'is_active'))
            AND NOT has_column_privilege(
                'operations_hub_auth_reader', 'public.users', column_name,
                'INSERT,UPDATE,REFERENCES'
            ), 'Reader: least privilege on users.' || column_name
        );
    END LOOP;

    PERFORM pg_temp.record_check(
        NOT has_table_privilege(
            'operations_hub_auth_reader', 'public.users',
            'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'
        ), 'Reader: no whole-table privileges on users'
    );
END;
$$;

-- Exercise default privileges on a genuinely new public table created by
-- postgres. Use a random name; no existing table is touched. ROLLBACK removes it.
DO $$
DECLARE
    probe_name text := 'identity_defaults_probe_' || replace(gen_random_uuid()::text, '-', '');
    browser_role text;
BEGIN
    EXECUTE format('CREATE TABLE public.%I (id integer)', probe_name);
    FOREACH browser_role IN ARRAY ARRAY['anon', 'authenticated'] LOOP
        PERFORM pg_temp.record_check(
            NOT has_table_privilege(
                browser_role, format('public.%I', probe_name),
                'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'
            )
            AND NOT has_any_column_privilege(
                browser_role, format('public.%I', probe_name),
                'SELECT,INSERT,UPDATE,REFERENCES'
            ), browser_role || ': no default privileges on future postgres tables'
        );
    END LOOP;
END;
$$;

CREATE TEMP TABLE identity_test_cases (
    test_name text,
    supplied_identity text,
    expected_actor uuid,
    expected_active_user uuid
);

-- Prepare synthetic profiles with administrator privileges.
DO $$
DECLARE
    test_org uuid := gen_random_uuid();
    active_user uuid := gen_random_uuid();
    inactive_user uuid := gen_random_uuid();
    missing_user uuid := gen_random_uuid();
BEGIN
    INSERT INTO public.organizations (id, name)
    VALUES (test_org, 'Identity Verification Organization');
    INSERT INTO auth.users (id) VALUES (active_user), (inactive_user);
    INSERT INTO public.users (id, organization_id, email, full_name, is_active)
    VALUES
        (active_user, test_org, active_user::text || '@example.invalid', 'Active Test User', true),
        (inactive_user, test_org, inactive_user::text || '@example.invalid', 'Inactive Test User', false);

    INSERT INTO identity_test_cases VALUES
        ('Empty identity', '', NULL, NULL),
        ('Malformed identity', 'not-a-uuid', NULL, NULL),
        ('Valid UUID without a profile', missing_user::text, missing_user, NULL),
        ('Active user', active_user::text, active_user, active_user),
        ('Inactive user', inactive_user::text, inactive_user, NULL);
END;
$$;

GRANT SELECT ON identity_test_cases TO operations_hub_runtime;
GRANT INSERT, SELECT ON identity_test_results TO operations_hub_runtime;
GRANT EXECUTE ON FUNCTION pg_temp.record_check(boolean, text) TO operations_hub_runtime;

-- Temporary test membership is entirely undone by ROLLBACK.
GRANT operations_hub_runtime TO postgres WITH INHERIT FALSE, SET TRUE;
SET LOCAL ROLE operations_hub_runtime;

DO $$
DECLARE
    test_case record;
    actual_actor uuid;
    actual_active_user uuid;
BEGIN
    PERFORM pg_temp.record_check(
        current_user = 'operations_hub_runtime', 'Helper behavior executes as runtime'
    );
    PERFORM pg_temp.record_check(
        identity_access.current_actor_id() IS NULL
        AND identity_access.current_active_user_id() IS NULL,
        'Missing identity'
    );

    FOR test_case IN SELECT * FROM pg_temp.identity_test_cases LOOP
        PERFORM set_config('app.user_id', test_case.supplied_identity, true);
        actual_actor := identity_access.current_actor_id();
        actual_active_user := identity_access.current_active_user_id();
        PERFORM pg_temp.record_check(
            actual_actor IS NOT DISTINCT FROM test_case.expected_actor
            AND actual_active_user IS NOT DISTINCT FROM test_case.expected_active_user,
            test_case.test_name
        );
    END LOOP;

    -- Privilege metadata is backed by actual denied operations.
    BEGIN
        PERFORM id FROM public.users LIMIT 1;
        RAISE EXCEPTION 'FAIL: runtime directly read users';
    EXCEPTION WHEN insufficient_privilege THEN
        PERFORM pg_temp.record_check(true, 'Runtime direct users SELECT denied');
    END;

    BEGIN
        EXECUTE 'SET LOCAL ROLE operations_hub_auth_reader';
        RAISE EXCEPTION 'FAIL: runtime became helper owner';
    EXCEPTION WHEN insufficient_privilege THEN
        PERFORM pg_temp.record_check(true, 'Runtime SET ROLE helper denied');
    END;
END;
$$;

SELECT * FROM identity_test_results ORDER BY test_name;
ROLLBACK;

-- ============================================================
-- SAME-CONNECTION TRANSACTION CLEANUP
-- These checks must not be run individually on different connections.
-- They use no application fixtures and never commit test data.
-- ============================================================
DO $$
BEGIN
    IF current_user <> 'postgres'
       OR NULLIF(current_setting('app.user_id', true), '') IS NOT NULL
       OR pg_has_role('postgres', 'operations_hub_runtime', 'SET') THEN
        RAISE EXCEPTION 'FAIL: main test rollback did not restore context/membership';
    END IF;
END;
$$;

-- COMMIT case: set identity as runtime, then remove the temporary membership
-- before committing. The automatic ADMIN-only creator link remains unchanged.
BEGIN;
GRANT operations_hub_runtime TO postgres WITH INHERIT FALSE, SET TRUE;
SET LOCAL ROLE operations_hub_runtime;
DO $$
DECLARE
    actor uuid := gen_random_uuid();
BEGIN
    IF identity_access.current_actor_id() IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL: identity leaked into commit test';
    END IF;
    PERFORM set_config('app.user_id', actor::text, true);
    IF identity_access.current_actor_id() IS DISTINCT FROM actor THEN
        RAISE EXCEPTION 'FAIL: identity was not set during commit test';
    END IF;
END;
$$;
RESET ROLE;
REVOKE operations_hub_runtime FROM postgres;
COMMIT;

DO $$
BEGIN
    IF current_user <> 'postgres'
       OR NULLIF(current_setting('app.user_id', true), '') IS NOT NULL
       OR pg_has_role('postgres', 'operations_hub_runtime', 'SET') THEN
        RAISE EXCEPTION 'FAIL: COMMIT leaked identity or temporary membership';
    END IF;
END;
$$;

-- ROLLBACK case: the next runtime transaction must start without the prior ID.
BEGIN;
GRANT operations_hub_runtime TO postgres WITH INHERIT FALSE, SET TRUE;
SET LOCAL ROLE operations_hub_runtime;
DO $$
DECLARE
    actor uuid := gen_random_uuid();
BEGIN
    IF identity_access.current_actor_id() IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL: identity leaked into next runtime transaction';
    END IF;
    PERFORM set_config('app.user_id', actor::text, true);
    IF identity_access.current_actor_id() IS DISTINCT FROM actor THEN
        RAISE EXCEPTION 'FAIL: identity was not set during rollback test';
    END IF;
END;
$$;
ROLLBACK;

DO $$
BEGIN
    IF current_user <> 'postgres'
       OR NULLIF(current_setting('app.user_id', true), '') IS NOT NULL
       OR pg_has_role('postgres', 'operations_hub_runtime', 'SET') THEN
        RAISE EXCEPTION 'FAIL: ROLLBACK leaked identity or temporary membership';
    END IF;
END;
$$;

SELECT 'PASS: all assertions completed; same-connection COMMIT and ROLLBACK cleanup verified'
    AS final_result;
