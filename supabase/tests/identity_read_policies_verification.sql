-- Run on LOCAL Supabase as postgres after migrations 1-5, in one connection.
-- psql <local-connection> -X -v ON_ERROR_STOP=1 -f <this-file>
-- Setup and fixture changes use postgres; every visibility assertion uses the
-- actual runtime role and SELECTs the protected table, not just the helper.
-- Everything (including temporary membership and catalog changes) rolls back.
-- On any SQL Editor error, issue ROLLBACK and stop before retrying.
BEGIN;

DO $$
BEGIN
    IF current_user <> 'postgres' THEN
        RAISE EXCEPTION 'Run setup as postgres';
    END IF;
    IF NULLIF(current_setting('app.user_id', true), '') IS NOT NULL
       OR pg_has_role('postgres', 'operations_hub_runtime', 'SET') THEN
        RAISE EXCEPTION 'Use a fresh session without identity or runtime SET membership';
    END IF;
END;
$$;

-- Random IDs avoid collisions. Labels keep the expected outcomes readable.
CREATE TEMP TABLE read_ids (key text PRIMARY KEY, id uuid NOT NULL UNIQUE);
INSERT INTO read_ids
SELECT key, gen_random_uuid() FROM unnest(ARRAY[
    'org_a', 'org_b', 'brand_a', 'brand_b', 'brand_off', 'brand_foreign',
    'store_a', 'store_b', 'store_unassigned', 'store_other_brand',
    'store_off', 'store_off_brand', 'store_foreign',
    'admin_org', 'admin_brand', 'worker', 'employee', 'admin_foreign',
    'unassigned', 'inactive', 'no_profile', 'no_read'
]) AS t(key);

CREATE FUNCTION pg_temp.read_id(label text) RETURNS uuid
LANGUAGE sql STABLE SECURITY INVOKER AS $$
    SELECT id FROM pg_temp.read_ids WHERE key = label
$$;

INSERT INTO public.organizations (id, name)
SELECT id, key FROM read_ids WHERE key IN ('org_a', 'org_b');

INSERT INTO public.brands (id, organization_id, name, slug, is_active)
SELECT id,
       pg_temp.read_id(CASE WHEN key = 'brand_foreign' THEN 'org_b' ELSE 'org_a' END),
       key, 'read-test-' || id::text, key <> 'brand_off'
FROM read_ids WHERE key IN ('brand_a', 'brand_b', 'brand_off', 'brand_foreign');

INSERT INTO public.locations (id, brand_id, name, timezone, is_active)
SELECT pg_temp.read_id(v.store), pg_temp.read_id(v.brand), v.store,
       'America/Los_Angeles', v.store <> 'store_off'
FROM (VALUES
    ('store_a', 'brand_a'), ('store_b', 'brand_a'),
    ('store_unassigned', 'brand_a'), ('store_off', 'brand_a'),
    ('store_other_brand', 'brand_b'), ('store_off_brand', 'brand_off'),
    ('store_foreign', 'brand_foreign')
) AS v(store, brand);

INSERT INTO auth.users (id)
SELECT id FROM read_ids WHERE key IN (
    'admin_org', 'admin_brand', 'worker', 'employee', 'admin_foreign',
    'unassigned', 'inactive', 'no_profile', 'no_read'
);
INSERT INTO public.users (id, organization_id, email, full_name, is_active)
SELECT id,
       pg_temp.read_id(CASE WHEN key = 'admin_foreign' THEN 'org_b' ELSE 'org_a' END),
       id::text || '@example.invalid', key, key <> 'inactive'
FROM read_ids WHERE key IN (
    'admin_org', 'admin_brand', 'worker', 'employee', 'admin_foreign',
    'unassigned', 'inactive', 'no_read'
);

INSERT INTO public.user_roles (user_id, organization_id, role_id, role_scope, brand_id)
SELECT pg_temp.read_id(v.actor), pg_temp.read_id(v.org), r.id, r.scope,
       pg_temp.read_id(v.brand)
FROM (VALUES
    ('admin_org', 'org_a', 'org_admin', NULL::text),
    ('admin_brand', 'org_a', 'brand_admin', 'brand_a'),
    ('admin_foreign', 'org_b', 'org_admin', NULL::text),
    ('inactive', 'org_a', 'org_admin', NULL::text)
) AS v(actor, org, role_key, brand)
JOIN public.roles r ON r.key = v.role_key;

-- Synthetic role has a real permission, but deliberately lacks locations.read.
-- This verifies that merely having an assignment does not grant location reads.
INSERT INTO public.roles (key, name, scope)
VALUES ('verification_no_location_read', 'Verification only', 'location');
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM public.roles r CROSS JOIN public.permissions p
WHERE r.key = 'verification_no_location_read' AND p.key = 'users.read';

INSERT INTO public.user_locations (user_id, location_id, organization_id, brand_id, role_id)
SELECT pg_temp.read_id(v.actor), pg_temp.read_id(v.store), pg_temp.read_id('org_a'),
       l.brand_id, r.id
FROM (VALUES
    ('worker', 'store_a', 'location_manager'),
    ('worker', 'store_b', 'employee'),
    ('worker', 'store_off', 'employee'),
    ('worker', 'store_off_brand', 'employee'),
    ('employee', 'store_b', 'employee'),
    ('no_read', 'store_a', 'verification_no_location_read'),
    -- Overlapping org and location grants must not duplicate rows.
    ('admin_org', 'store_a', 'employee')
) AS v(actor, store, role_key)
JOIN public.locations l ON l.id = pg_temp.read_id(v.store)
JOIN public.roles r ON r.key = v.role_key;

CREATE TEMP TABLE read_results (test text PRIMARY KEY);
CREATE FUNCTION pg_temp.check_read(ok boolean, label text) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER AS $$
BEGIN
    IF ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL: %', label;
    END IF;
    INSERT INTO pg_temp.read_results VALUES (label);
END;
$$;

-- Assert exact IDs, not just counts. Unexpected rows from ANY organization,
-- including pre-existing local data, fail the test. Empty expected arrays mean
-- deny all. Both calls run as runtime, while the production helper keeps its
-- own SECURITY DEFINER owner. These test helpers are SECURITY INVOKER.
CREATE FUNCTION pg_temp.expect_locations(actor text, expected text[], label text)
RETURNS void LANGUAGE plpgsql SECURITY INVOKER AS $$
DECLARE
    wanted uuid[];
    actual uuid[];
    helper_ids uuid[];
BEGIN
    IF current_user <> 'operations_hub_runtime' THEN
        RAISE EXCEPTION 'Visibility assertions must run as runtime';
    END IF;
    PERFORM set_config('app.user_id', COALESCE(pg_temp.read_id(actor)::text, ''), true);
    SELECT COALESCE(array_agg(pg_temp.read_id(x) ORDER BY pg_temp.read_id(x)), ARRAY[]::uuid[])
    INTO wanted FROM unnest(expected) AS t(x);
    SELECT COALESCE(array_agg(id ORDER BY id), ARRAY[]::uuid[])
    INTO actual FROM public.locations;
    SELECT COALESCE(array_agg(id ORDER BY id), ARRAY[]::uuid[])
    INTO helper_ids FROM identity_access.current_readable_location_ids() AS t(id);
    PERFORM pg_temp.check_read(actual = wanted AND helper_ids = wanted, label);
END;
$$;

-- Check the security configuration before exercising the policy.
SELECT pg_temp.check_read(
    (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.locations'::regclass),
    'RLS enabled on locations'
);
SELECT pg_temp.check_read(
    (SELECT p.prosecdef AND p.provolatile = 's'
       AND p.proowner = 'operations_hub_auth_reader'::regrole
       AND 'search_path=""' = ANY(p.proconfig)
     FROM pg_proc p
     WHERE p.oid = 'identity_access.current_readable_location_ids()'::regprocedure),
    'Helper owner, SECURITY DEFINER, STABLE, fixed search_path'
);
DO $$
DECLARE browser_role text;
BEGIN
    FOREACH browser_role IN ARRAY ARRAY['anon', 'authenticated'] LOOP
        PERFORM pg_temp.check_read(
            NOT has_function_privilege(browser_role,
                'identity_access.current_readable_location_ids()', 'EXECUTE')
            AND NOT has_schema_privilege(browser_role, 'identity_access', 'USAGE,CREATE')
            AND NOT has_table_privilege(browser_role, 'public.locations',
                'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')
            AND NOT has_any_column_privilege(browser_role, 'public.locations',
                'SELECT,INSERT,UPDATE,REFERENCES'),
            browser_role || ': no helper or location access'
        );
    END LOOP;
END;
$$;
SELECT pg_temp.check_read(
    NOT pg_has_role('operations_hub_runtime', 'operations_hub_auth_reader', 'MEMBER')
    AND NOT pg_has_role('postgres', 'operations_hub_auth_reader', 'SET')
    AND NOT has_schema_privilege('operations_hub_auth_reader', 'identity_access', 'CREATE')
    AND (SELECT NOT rolsuper AND NOT rolbypassrls AND NOT rolcanlogin
         FROM pg_roles WHERE rolname = 'operations_hub_runtime'),
    'Runtime cannot bypass RLS; temporary helper privileges removed'
);

GRANT SELECT ON read_ids TO operations_hub_runtime;
GRANT INSERT ON read_results TO operations_hub_runtime;
GRANT operations_hub_runtime TO postgres WITH INHERIT FALSE, SET TRUE;
SET LOCAL ROLE operations_hub_runtime;

-- Missing and malformed identities must fail closed, without throwing a UUID error.
SELECT pg_temp.check_read(
    (SELECT count(*) = 0 FROM public.locations)
    AND (SELECT count(*) = 0 FROM identity_access.current_readable_location_ids()),
    'Missing identity sees nothing'
);
SELECT set_config('app.user_id', 'not-a-uuid', true);
SELECT pg_temp.check_read(
    (SELECT count(*) = 0 FROM public.locations)
    AND (SELECT count(*) = 0 FROM identity_access.current_readable_location_ids()),
    'Malformed identity sees nothing'
);

SELECT pg_temp.expect_locations(NULL, ARRAY[]::text[], 'Empty identity sees nothing');
SELECT pg_temp.expect_locations('no_profile', ARRAY[]::text[], 'Auth user without profile sees nothing');
SELECT pg_temp.expect_locations('unassigned', ARRAY[]::text[], 'Active unassigned user sees nothing');
SELECT pg_temp.expect_locations('inactive', ARRAY[]::text[], 'Inactive org admin sees nothing');
SELECT pg_temp.expect_locations('no_read', ARRAY[]::text[], 'Assignment without locations.read sees nothing');
SELECT pg_temp.expect_locations('admin_org',
    ARRAY['store_a', 'store_b', 'store_unassigned', 'store_other_brand'],
    'Org admin: own organization only, active targets only, no duplicates');
SELECT pg_temp.expect_locations('admin_brand', ARRAY['store_a', 'store_b', 'store_unassigned'],
    'Brand admin: own brand only, inactive location excluded');
SELECT pg_temp.expect_locations('worker', ARRAY['store_a', 'store_b'],
    'Manager A and employee B: no unassigned sibling or inactive targets');
SELECT pg_temp.expect_locations('employee', ARRAY['store_b'], 'Employee: assigned store only');
SELECT pg_temp.expect_locations('admin_foreign', ARRAY['store_foreign'], 'Other org admin: isolation in reverse');
SELECT pg_temp.expect_locations('admin_org',
    ARRAY['store_a', 'store_b', 'store_unassigned', 'store_other_brand'],
    'Same connection switches back to original organization');

-- Targeting a forbidden ID explicitly must not defeat the policy.
SELECT pg_temp.expect_locations('employee', ARRAY['store_b'], 'Switch to employee for direct query checks');
SELECT pg_temp.check_read(
    NOT EXISTS (SELECT 1 FROM public.locations WHERE id = pg_temp.read_id('store_a')),
    'Explicit forbidden ID is invisible'
);

-- SELECT access must not accidentally enable writes, even to a visible row.
DO $$
BEGIN
    BEGIN
        INSERT INTO public.locations (brand_id, name, timezone)
        VALUES (pg_temp.read_id('brand_a'), 'Forbidden insert', 'UTC');
        RAISE EXCEPTION 'INSERT unexpectedly succeeded';
    EXCEPTION WHEN insufficient_privilege THEN
        PERFORM pg_temp.check_read(true, 'Runtime INSERT denied');
    END;
    BEGIN
        UPDATE public.locations SET name = 'Forbidden update'
        WHERE id = pg_temp.read_id('store_b');
        RAISE EXCEPTION 'UPDATE unexpectedly succeeded';
    EXCEPTION WHEN insufficient_privilege THEN
        PERFORM pg_temp.check_read(true, 'Runtime UPDATE denied');
    END;
    BEGIN
        DELETE FROM public.locations WHERE id = pg_temp.read_id('store_b');
        RAISE EXCEPTION 'DELETE unexpectedly succeeded';
    EXCEPTION WHEN insufficient_privilege THEN
        PERFORM pg_temp.check_read(true, 'Runtime DELETE denied');
    END;
END;
$$;

-- Fixture changes are administrative setup, not tests of write authorization.
RESET ROLE;
UPDATE public.locations SET is_active = false WHERE id = pg_temp.read_id('store_a');
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.expect_locations('worker', ARRAY['store_b'], 'Location deactivation immediately removes access');
SELECT pg_temp.expect_locations('admin_org', ARRAY['store_b', 'store_unassigned', 'store_other_brand'],
    'Org scope does not bypass location deactivation');

RESET ROLE;
UPDATE public.brands SET is_active = false WHERE id = pg_temp.read_id('brand_a');
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.expect_locations('worker', ARRAY[]::text[], 'Brand deactivation removes location-level access');
SELECT pg_temp.expect_locations('admin_brand', ARRAY[]::text[], 'Brand deactivation removes brand-level access');
SELECT pg_temp.expect_locations('admin_org', ARRAY['store_other_brand'], 'Org scope does not bypass brand deactivation');

RESET ROLE;
UPDATE public.brands SET is_active = true WHERE id = pg_temp.read_id('brand_a');
UPDATE public.locations SET is_active = true WHERE id = pg_temp.read_id('store_a');
UPDATE public.users SET is_active = false WHERE id = pg_temp.read_id('worker');
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.expect_locations('worker', ARRAY[]::text[], 'User deactivation removes access');

RESET ROLE;
UPDATE public.users SET is_active = true WHERE id = pg_temp.read_id('worker');
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.expect_locations('worker', ARRAY['store_a', 'store_b'], 'Reactivation restores eligible assignments');

RESET ROLE;
DELETE FROM public.user_locations
WHERE user_id = pg_temp.read_id('worker') AND location_id = pg_temp.read_id('store_a');
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.expect_locations('worker', ARRAY['store_b'], 'Revoking one location preserves the other');
RESET ROLE;
DELETE FROM public.user_locations WHERE user_id = pg_temp.read_id('worker');
DELETE FROM public.user_roles WHERE user_id = pg_temp.read_id('admin_brand');
-- Org admin also had a location grant; revoke that to test an empty result.
DELETE FROM public.user_roles WHERE user_id = pg_temp.read_id('admin_org');
DELETE FROM public.user_locations WHERE user_id = pg_temp.read_id('admin_org');
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.expect_locations('worker', ARRAY[]::text[], 'Revoking all location assignments removes access');
SELECT pg_temp.expect_locations('admin_brand', ARRAY[]::text[], 'Revoking brand assignment removes access');
SELECT pg_temp.expect_locations('admin_org', ARRAY[]::text[], 'Revoking organization and overlapping assignments removes access');

RESET ROLE;
SELECT 'PASS: ' || test AS result FROM read_results ORDER BY test;
SELECT count(*) AS passed_checks FROM read_results;
ROLLBACK;
-- No application data, catalog edits, or role grants survive this file.
