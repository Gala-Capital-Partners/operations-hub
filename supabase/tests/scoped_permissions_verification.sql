-- Scoped-permission helper verification (after migrations 1-4).
-- Run the entire file on LOCAL Supabase as postgres, using one connection.
-- With psql, use -X -v ON_ERROR_STOP=1 -f <this-file> to stop on any failure.
-- In SQL Editor, stop on an error and issue ROLLBACK before retrying.
-- Each of the five groups has its own BEGIN/ROLLBACK: fixtures, temporary
-- objects, role membership grants, and request identity changes are undone.
-- Assertions call the helper as operations_hub_runtime; fixture mutations
-- use postgres. These tests do not verify write authorization or resource RLS.

-- 1. Exact location-scoped grants: manager at A, employee at B.
BEGIN;

CREATE TEMP TABLE scoped_test_actor (
    user_id uuid
);

CREATE TEMP TABLE expected_scoped_permissions (
    role_key text,
    permission_key text,
    role_scope text,
    organization_id uuid,
    brand_id uuid,
    location_id uuid
);

-- Create the test data as postgres.
DO $$
DECLARE
    test_org uuid := gen_random_uuid();
    test_brand uuid := gen_random_uuid();
    store_a uuid := gen_random_uuid();
    store_b uuid := gen_random_uuid();
    bob uuid := gen_random_uuid();
    manager_role uuid;
    employee_role uuid;
BEGIN
    -- STRICT makes the test fail if a required catalog role is missing.
    SELECT id INTO STRICT manager_role
    FROM public.roles
    WHERE key = 'location_manager';

    SELECT id INTO STRICT employee_role
    FROM public.roles
    WHERE key = 'employee';

    INSERT INTO public.organizations (id, name)
    VALUES (test_org, 'Scoped Permission Test Organization');

    INSERT INTO public.brands (
        id, organization_id, name, slug
    )
    VALUES (
        test_brand,
        test_org,
        'Scoped Permission Test Brand',
        'test-' || test_brand::text
    );

    INSERT INTO public.locations (
        id, brand_id, name, timezone
    )
    VALUES
        (store_a, test_brand, 'Store A', 'America/Los_Angeles'),
        (store_b, test_brand, 'Store B', 'America/Los_Angeles');

    -- Local test identity only.
    INSERT INTO auth.users (id)
    VALUES (bob);

    INSERT INTO public.users (
        id, organization_id, email, full_name
    )
    VALUES (
        bob,
        test_org,
        bob::text || '@example.invalid',
        'Bob Verification'
    );

    INSERT INTO public.user_locations (
        user_id, location_id, organization_id, brand_id, role_id
    )
    VALUES
        (bob, store_a, test_org, test_brand, manager_role),
        (bob, store_b, test_org, test_brand, employee_role);

    INSERT INTO scoped_test_actor VALUES (bob);

    -- Expected results come from the approved matrix.
    -- They are independent of the helper being tested.
    INSERT INTO expected_scoped_permissions
    SELECT
        'location_manager',
        permission_key,
        'location',
        test_org,
        test_brand,
        store_a
    FROM unnest(ARRAY[
        'locations.read',
        'users.read',
        'users.invite',
        'role_assignments.read',
        'role_assignments.manage',
        'tasks.manage',
        'task_instances.read',
        'task_instances.complete',
        'task_instances.reopen',
        'reports.read'
    ]) AS permissions(permission_key);

    INSERT INTO expected_scoped_permissions
    SELECT
        'employee',
        permission_key,
        'location',
        test_org,
        test_brand,
        store_b
    FROM unnest(ARRAY[
        'locations.read',
        'users.read',
        'role_assignments.read',
        'task_instances.read',
        'task_instances.complete'
    ]) AS permissions(permission_key);
END;
$$;

-- Grant access only to the temporary test expectations.
GRANT SELECT ON scoped_test_actor, expected_scoped_permissions
TO operations_hub_runtime;

-- Temporary test membership; ROLLBACK restores its previous state.
GRANT operations_hub_runtime TO postgres
WITH INHERIT FALSE, SET TRUE;

SET LOCAL ROLE operations_hub_runtime;

DO $$
DECLARE
    bob uuid;
BEGIN
    IF current_user <> 'operations_hub_runtime' THEN
        RAISE EXCEPTION 'FAIL: test must run as runtime role';
    END IF;

    SELECT user_id INTO STRICT bob
    FROM pg_temp.scoped_test_actor;

    PERFORM set_config('app.user_id', bob::text, true);

    -- Missing expected rows are failures.
    IF EXISTS (
        SELECT * FROM pg_temp.expected_scoped_permissions
        EXCEPT
        SELECT * FROM identity_access.current_user_permissions()
    ) THEN
        RAISE EXCEPTION 'FAIL: expected scoped permissions are missing';
    END IF;

    -- Additional or incorrectly scoped rows are failures.
    IF EXISTS (
        SELECT * FROM identity_access.current_user_permissions()
        EXCEPT
        SELECT * FROM pg_temp.expected_scoped_permissions
    ) THEN
        RAISE EXCEPTION 'FAIL: unexpected or incorrectly scoped permissions';
    END IF;

    -- EXCEPT compares sets, so check the count separately for duplicates.
    IF (
        SELECT count(*)
        FROM identity_access.current_user_permissions()
    ) <> 15 THEN
        RAISE EXCEPTION 'FAIL: expected exactly 15 permission rows';
    END IF;
END;
$$;

SELECT
    'PASS: manager grants stay at Store A; employee grants stay at Store B'
        AS test_result,
    current_user AS executed_as;

-- Display the actual grants so you can inspect them.
SELECT *
FROM identity_access.current_user_permissions()
ORDER BY role_key, permission_key;

ROLLBACK;

-- 2. Same-connection identity switching: Alice -> Bob -> Alice.
-- An active user without assignments receives no operational grants.
BEGIN;

CREATE TEMP TABLE isolation_test_context (
    organization_id uuid,
    alice_id uuid,
    bob_id uuid
);

DO $$
DECLARE
    test_org uuid := gen_random_uuid();
    alice uuid := gen_random_uuid();
    bob uuid := gen_random_uuid();
    admin_role uuid;
BEGIN
    SELECT id INTO STRICT admin_role
    FROM public.roles
    WHERE key = 'org_admin';

    INSERT INTO public.organizations (id, name)
    VALUES (test_org, 'User Isolation Test');

    INSERT INTO auth.users (id)
    VALUES (alice), (bob);

    INSERT INTO public.users (
        id, organization_id, email, full_name
    )
    VALUES
        (
            alice, test_org,
            alice::text || '@example.invalid', 'Alice Test'
        ),
        (
            bob, test_org,
            bob::text || '@example.invalid', 'Bob Test'
        );

    -- Only Alice receives a role.
    -- Bob is active and in the same organization, but has no assignments.
    INSERT INTO public.user_roles (
        user_id, organization_id, role_id, role_scope, brand_id
    )
    VALUES (
        alice, test_org, admin_role, 'organization', NULL
    );

    INSERT INTO isolation_test_context
    VALUES (test_org, alice, bob);
END;
$$;

GRANT SELECT ON isolation_test_context
TO operations_hub_runtime;

GRANT operations_hub_runtime TO postgres
WITH INHERIT FALSE, SET TRUE;

SET LOCAL ROLE operations_hub_runtime;

DO $$
DECLARE
    context record;
    expected_permissions text[] := ARRAY[
        'locations.read',
        'reports.read',
        'role_assignments.manage',
        'role_assignments.read',
        'task_instances.read',
        'tasks.manage',
        'users.deactivate',
        'users.invite',
        'users.read'
    ];
    actual_permissions text[];
BEGIN
    IF current_user <> 'operations_hub_runtime' THEN
        RAISE EXCEPTION 'FAIL: not executing as runtime role';
    END IF;

    SELECT * INTO STRICT context
    FROM pg_temp.isolation_test_context;

    -- 1. Alice receives exactly her nine organization permissions.
    PERFORM set_config('app.user_id', context.alice_id::text, true);

    SELECT array_agg(permission_key ORDER BY permission_key)
    INTO actual_permissions
    FROM identity_access.current_user_permissions();

    IF actual_permissions IS DISTINCT FROM expected_permissions THEN
        RAISE EXCEPTION 'FAIL: unexpected permissions for Alice';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM identity_access.current_user_permissions() AS grants
        WHERE grants.role_key IS DISTINCT FROM 'org_admin'
           OR grants.role_scope IS DISTINCT FROM 'organization'
           OR grants.organization_id
                IS DISTINCT FROM context.organization_id
           OR grants.brand_id IS NOT NULL
           OR grants.location_id IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'FAIL: incorrect scope or target for Alice';
    END IF;

    -- 2. Switch to Bob on the SAME connection.
    PERFORM set_config('app.user_id', context.bob_id::text, true);

    -- Confirm Bob is a valid active user, not merely a missing identity.
    IF identity_access.current_active_user_id()
        IS DISTINCT FROM context.bob_id THEN
        RAISE EXCEPTION 'FAIL: Bob should be an active user';
    END IF;

    IF EXISTS (
        SELECT 1 FROM identity_access.current_user_permissions()
    ) THEN
        RAISE EXCEPTION
            'FAIL: Bob received permissions despite having no assignments';
    END IF;

    -- 3. Switch back to Alice: the helper must resolve her grants again.
    PERFORM set_config('app.user_id', context.alice_id::text, true);

    SELECT array_agg(permission_key ORDER BY permission_key)
    INTO actual_permissions
    FROM identity_access.current_user_permissions();

    IF actual_permissions IS DISTINCT FROM expected_permissions THEN
        RAISE EXCEPTION
            'FAIL: Alice permissions were not restored after switching back';
    END IF;
END;
$$;

SELECT
    'PASS: Alice -> Bob -> Alice returns only each user''s grants'
        AS test_result,
    current_user AS executed_as;

ROLLBACK;

-- 3. Effective helper privileges, ownership, and temporary-grant cleanup.
-- These are metadata assertions; behavior is exercised by the other groups.
BEGIN;

DO $$
DECLARE
    browser_role text;
BEGIN
    FOREACH browser_role IN ARRAY ARRAY['anon', 'authenticated']
    LOOP
        IF has_schema_privilege(
            browser_role,
            'identity_access',
            'USAGE,CREATE'
        ) THEN
            RAISE EXCEPTION
                'FAIL: % has helper-schema privileges', browser_role;
        END IF;

        IF has_function_privilege(
            browser_role,
            'identity_access.current_user_permissions()',
            'EXECUTE'
        ) THEN
            RAISE EXCEPTION
                'FAIL: % can execute the permissions helper', browser_role;
        END IF;
    END LOOP;

    IF NOT has_schema_privilege(
        'operations_hub_runtime',
        'identity_access',
        'USAGE'
    ) THEN
        RAISE EXCEPTION 'FAIL: runtime lacks helper-schema USAGE';
    END IF;

    IF NOT has_function_privilege(
        'operations_hub_runtime',
        'identity_access.current_user_permissions()',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'FAIL: runtime cannot execute the permissions helper';
    END IF;

    IF has_schema_privilege(
        'operations_hub_runtime',
        'identity_access',
        'CREATE'
    ) THEN
        RAISE EXCEPTION 'FAIL: runtime can create helper-schema objects';
    END IF;

    IF has_schema_privilege(
        'operations_hub_auth_reader',
        'identity_access',
        'CREATE'
    ) THEN
        RAISE EXCEPTION 'FAIL: temporary reader CREATE privilege remains';
    END IF;

    IF pg_has_role(
        'operations_hub_runtime',
        'operations_hub_auth_reader',
        'MEMBER'
    ) THEN
        RAISE EXCEPTION 'FAIL: runtime belongs to the privileged helper role';
    END IF;

    IF pg_has_role(
        'postgres',
        'operations_hub_auth_reader',
        'SET'
    ) THEN
        RAISE EXCEPTION 'FAIL: temporary ownership-transfer membership remains';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_proc
        WHERE oid =
            'identity_access.current_user_permissions()'::regprocedure
          AND proowner = 'operations_hub_auth_reader'::regrole
          AND prosecdef
          AND provolatile = 's'
          AND proconfig @> ARRAY['search_path=""']
    ) THEN
        RAISE EXCEPTION
            'FAIL: unexpected helper owner, execution mode, or search path';
    END IF;
END;
$$;

SELECT
    'PASS: helper privileges, ownership, and cleanup are correct'
        AS test_result;

ROLLBACK;

-- 4. Removing one location assignment preserves grants from the other.
-- Removing all assignments leaves the account active but without grants.
BEGIN;

CREATE TEMP TABLE revocation_test_context (
    organization_id uuid,
    brand_id uuid,
    store_a_id uuid,
    store_b_id uuid,
    user_id uuid
);

CREATE TEMP TABLE revocation_test_results (
    step integer,
    test_name text,
    result text
);

DO $$
DECLARE
    test_org uuid := gen_random_uuid();
    test_brand uuid := gen_random_uuid();
    store_a uuid := gen_random_uuid();
    store_b uuid := gen_random_uuid();
    bob uuid := gen_random_uuid();
    manager_role uuid;
    employee_role uuid;
BEGIN
    SELECT id INTO STRICT manager_role
    FROM public.roles WHERE key = 'location_manager';

    SELECT id INTO STRICT employee_role
    FROM public.roles WHERE key = 'employee';

    INSERT INTO public.organizations (id, name)
    VALUES (test_org, 'Revocation Test Organization');

    INSERT INTO public.brands (id, organization_id, name, slug)
    VALUES (
        test_brand, test_org, 'Revocation Test Brand',
        'test-' || test_brand::text
    );

    INSERT INTO public.locations (id, brand_id, name, timezone)
    VALUES
        (store_a, test_brand, 'Store A', 'America/Los_Angeles'),
        (store_b, test_brand, 'Store B', 'America/Los_Angeles');

    INSERT INTO auth.users (id) VALUES (bob);

    INSERT INTO public.users (
        id, organization_id, email, full_name
    )
    VALUES (
        bob, test_org,
        bob::text || '@example.invalid',
        'Bob Revocation Test'
    );

    INSERT INTO public.user_locations (
        user_id, location_id, organization_id, brand_id, role_id
    )
    VALUES
        (bob, store_a, test_org, test_brand, manager_role),
        (bob, store_b, test_org, test_brand, employee_role);

    INSERT INTO revocation_test_context
    VALUES (test_org, test_brand, store_a, store_b, bob);
END;
$$;

GRANT SELECT ON revocation_test_context TO operations_hub_runtime;
GRANT INSERT, SELECT ON revocation_test_results TO operations_hub_runtime;

GRANT operations_hub_runtime TO postgres
WITH INHERIT FALSE, SET TRUE;

SELECT set_config('app.user_id', user_id::text, true)
FROM revocation_test_context;

-- Establish that grants exist before revocation.
SET LOCAL ROLE operations_hub_runtime;

DO $$
BEGIN
    IF (
        SELECT count(*)
        FROM identity_access.current_user_permissions()
    ) <> 15 THEN
        RAISE EXCEPTION 'FAIL: expected 15 initial grants';
    END IF;

    INSERT INTO revocation_test_results
    VALUES (1, 'Initial manager and employee grants exist', 'PASS');
END;
$$;

RESET ROLE;

-- Administrator removes only the Store A assignment.
DELETE FROM public.user_locations
WHERE user_id = (SELECT user_id FROM revocation_test_context)
  AND location_id = (SELECT store_a_id FROM revocation_test_context);

SET LOCAL ROLE operations_hub_runtime;

DO $$
DECLARE
    context record;
    actual_permissions text[];
BEGIN
    SELECT * INTO STRICT context
    FROM pg_temp.revocation_test_context;

    -- Assignment removal must not deactivate the user's profile.
    IF identity_access.current_active_user_id()
        IS DISTINCT FROM context.user_id THEN
        RAISE EXCEPTION 'FAIL: Bob should still be active';
    END IF;

    SELECT array_agg(permission_key ORDER BY permission_key)
    INTO actual_permissions
    FROM identity_access.current_user_permissions();

    IF actual_permissions IS DISTINCT FROM ARRAY[
        'locations.read',
        'role_assignments.read',
        'task_instances.complete',
        'task_instances.read',
        'users.read'
    ]::text[] THEN
        RAISE EXCEPTION 'FAIL: expected only five employee permissions';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM identity_access.current_user_permissions() AS g
        WHERE g.role_key IS DISTINCT FROM 'employee'
           OR g.role_scope IS DISTINCT FROM 'location'
           OR g.organization_id IS DISTINCT FROM context.organization_id
           OR g.brand_id IS DISTINCT FROM context.brand_id
           OR g.location_id IS DISTINCT FROM context.store_b_id
    ) THEN
        RAISE EXCEPTION 'FAIL: remaining grants have incorrect scope';
    END IF;

    INSERT INTO revocation_test_results
    VALUES (2, 'Manager grants removed; Store B employee grants preserved', 'PASS');
END;
$$;

RESET ROLE;

-- Remove the remaining assignment.
DELETE FROM public.user_locations
WHERE user_id = (SELECT user_id FROM revocation_test_context)
  AND location_id = (SELECT store_b_id FROM revocation_test_context);

SET LOCAL ROLE operations_hub_runtime;

DO $$
BEGIN
    IF identity_access.current_active_user_id()
        IS DISTINCT FROM (SELECT user_id FROM revocation_test_context) THEN
        RAISE EXCEPTION 'FAIL: Bob should remain active without assignments';
    END IF;

    IF EXISTS (
        SELECT 1 FROM identity_access.current_user_permissions()
    ) THEN
        RAISE EXCEPTION 'FAIL: grants remain after removing all assignments';
    END IF;

    INSERT INTO revocation_test_results
    VALUES (3, 'No assignments means no grants; user remains active', 'PASS');
END;
$$;

SELECT *
FROM revocation_test_results
ORDER BY step;

ROLLBACK;

-- 5. Sequential deactivation/reactivation; expected counts:
-- 32 -> 22 -> 9 -> 22 -> 32 -> 0 -> 32. This is not a concurrency test.
-- Organization grants remain when a brand is inactive. Later resource
-- policies must still reject ordinary operations on inactive targets.
BEGIN;

CREATE TEMP TABLE activity_test_context (
    organization_id uuid,
    brand_id uuid,
    store_a_id uuid,
    store_b_id uuid,
    user_id uuid
);

CREATE TEMP TABLE activity_test_results (
    step integer,
    test_name text,
    grant_count integer,
    executed_as text,
    result text
);

-- Prepare the fixtures.
DO $$
DECLARE
    test_org uuid := gen_random_uuid();
    test_brand uuid := gen_random_uuid();
    store_a uuid := gen_random_uuid();
    store_b uuid := gen_random_uuid();
    test_user uuid := gen_random_uuid();
    org_role uuid;
    brand_role uuid;
    manager_role uuid;
    employee_role uuid;
BEGIN
    SELECT id INTO STRICT org_role
    FROM public.roles WHERE key = 'org_admin';

    SELECT id INTO STRICT brand_role
    FROM public.roles WHERE key = 'brand_admin';

    SELECT id INTO STRICT manager_role
    FROM public.roles WHERE key = 'location_manager';

    SELECT id INTO STRICT employee_role
    FROM public.roles WHERE key = 'employee';

    INSERT INTO public.organizations (id, name)
    VALUES (test_org, 'Activity Verification Organization');

    INSERT INTO public.brands (id, organization_id, name, slug)
    VALUES (
        test_brand, test_org,
        'Activity Verification Brand',
        'test-' || test_brand::text
    );

    INSERT INTO public.locations (id, brand_id, name, timezone)
    VALUES
        (store_a, test_brand, 'Store A', 'America/Los_Angeles'),
        (store_b, test_brand, 'Store B', 'America/Los_Angeles');

    INSERT INTO auth.users (id) VALUES (test_user);

    INSERT INTO public.users (
        id, organization_id, email, full_name
    )
    VALUES (
        test_user, test_org,
        test_user::text || '@example.invalid',
        'Activity Verification User'
    );

    INSERT INTO public.user_roles (
        user_id, organization_id, role_id, role_scope, brand_id
    )
    VALUES
        (test_user, test_org, org_role, 'organization', NULL),
        (test_user, test_org, brand_role, 'brand', test_brand);

    INSERT INTO public.user_locations (
        user_id, location_id, organization_id, brand_id, role_id
    )
    VALUES
        (test_user, store_a, test_org, test_brand, manager_role),
        (test_user, store_b, test_org, test_brand, employee_role);

    INSERT INTO activity_test_context
    VALUES (test_org, test_brand, store_a, store_b, test_user);
END;
$$;

-- Test-only assertion helper uses SECURITY INVOKER. The runtime role
-- calls the production SECURITY DEFINER helper, which retains its own
-- narrowly privileged owner during execution.
CREATE FUNCTION pg_temp.check_activity(
    step_number integer,
    label text,
    expected_org integer,
    expected_brand integer,
    expected_manager integer,
    expected_employee integer
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    context record;
    actual_counts bigint[];
    total_count bigint;
BEGIN
    IF current_user <> 'operations_hub_runtime' THEN
        RAISE EXCEPTION 'FAIL: activity check must run as runtime';
    END IF;

    SELECT * INTO STRICT context
    FROM pg_temp.activity_test_context;

    -- Count each role only when its scope and target also match.
    SELECT
        ARRAY[
            count(*) FILTER (
                WHERE g.role_key = 'org_admin'
                  AND g.role_scope = 'organization'
                  AND g.organization_id = context.organization_id
                  AND g.brand_id IS NULL
                  AND g.location_id IS NULL
            ),
            count(*) FILTER (
                WHERE g.role_key = 'brand_admin'
                  AND g.role_scope = 'brand'
                  AND g.organization_id = context.organization_id
                  AND g.brand_id = context.brand_id
                  AND g.location_id IS NULL
            ),
            count(*) FILTER (
                WHERE g.role_key = 'location_manager'
                  AND g.role_scope = 'location'
                  AND g.organization_id = context.organization_id
                  AND g.brand_id = context.brand_id
                  AND g.location_id = context.store_a_id
            ),
            count(*) FILTER (
                WHERE g.role_key = 'employee'
                  AND g.role_scope = 'location'
                  AND g.organization_id = context.organization_id
                  AND g.brand_id = context.brand_id
                  AND g.location_id = context.store_b_id
            )
        ],
        count(*)
    INTO actual_counts, total_count
    FROM identity_access.current_user_permissions() AS g;

    IF actual_counts IS DISTINCT FROM ARRAY[
        expected_org, expected_brand, expected_manager, expected_employee
    ]::bigint[] THEN
        RAISE EXCEPTION
            'FAIL [%]: unexpected counts %', label, actual_counts;
    END IF;

    -- Catch any additional rows outside the expected roles/targets.
    IF total_count <>
        expected_org + expected_brand + expected_manager + expected_employee
    THEN
        RAISE EXCEPTION 'FAIL [%]: unexpected additional grants', label;
    END IF;

    INSERT INTO pg_temp.activity_test_results
    VALUES (step_number, label, total_count, current_user, 'PASS');
END;
$$;

GRANT SELECT ON activity_test_context TO operations_hub_runtime;
GRANT INSERT, SELECT ON activity_test_results TO operations_hub_runtime;

GRANT EXECUTE ON FUNCTION
    pg_temp.check_activity(integer, text, integer, integer, integer, integer)
TO operations_hub_runtime;

GRANT operations_hub_runtime TO postgres
WITH INHERIT FALSE, SET TRUE;

-- Keep the same actor throughout all changes.
SELECT set_config('app.user_id', user_id::text, true)
FROM activity_test_context;

-- 1. Everything active.
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.check_activity(1, 'Everything active', 9, 8, 10, 5);
RESET ROLE;

-- 2. Disable Store A. Its manager grant disappears.
UPDATE public.locations
SET is_active = false
WHERE id = (SELECT store_a_id FROM activity_test_context);

SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.check_activity(2, 'Store A inactive', 9, 8, 0, 5);
RESET ROLE;

-- 3. Disable the brand. Both brand and location grants disappear.
UPDATE public.brands
SET is_active = false
WHERE id = (SELECT brand_id FROM activity_test_context);

SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.check_activity(3, 'Brand inactive', 9, 0, 0, 0);
RESET ROLE;

-- 4. Restore the brand. Store A is still inactive.
UPDATE public.brands
SET is_active = true
WHERE id = (SELECT brand_id FROM activity_test_context);

SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.check_activity(4, 'Brand restored; Store A inactive', 9, 8, 0, 5);
RESET ROLE;

-- 5. Restore Store A.
UPDATE public.locations
SET is_active = true
WHERE id = (SELECT store_a_id FROM activity_test_context);

SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.check_activity(5, 'All targets restored', 9, 8, 10, 5);
RESET ROLE;

-- 6. Disable the user. All grants disappear, including organization grants.
UPDATE public.users
SET is_active = false
WHERE id = (SELECT user_id FROM activity_test_context);

SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.check_activity(6, 'User inactive', 0, 0, 0, 0);
RESET ROLE;

-- 7. Restore the user.
UPDATE public.users
SET is_active = true
WHERE id = (SELECT user_id FROM activity_test_context);

SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.check_activity(7, 'User restored', 9, 8, 10, 5);
RESET ROLE;

SELECT *
FROM activity_test_results
ORDER BY step;

ROLLBACK;
