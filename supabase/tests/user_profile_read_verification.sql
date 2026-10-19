-- LOCAL Supabase, after migrations 1-7; run the whole file as postgres.
-- psql <local-connection> -X -v ON_ERROR_STOP=1 -f <this-file>
-- Fixtures use postgres. Assertions use runtime and query the protected table.
-- All fixture data, catalog changes and temporary membership roll back.
-- In SQL Editor, stop and issue ROLLBACK on any error before retrying.
BEGIN;
DO $$ BEGIN
    IF current_user <> 'postgres'
       OR NULLIF(current_setting('app.user_id', true), '') IS NOT NULL
       OR pg_has_role('postgres', 'operations_hub_runtime', 'SET') THEN
        RAISE EXCEPTION 'Use a fresh postgres session without identity or runtime membership';
    END IF;
END $$;

CREATE TEMP TABLE profile_ids (key text PRIMARY KEY, id uuid UNIQUE NOT NULL DEFAULT gen_random_uuid());
INSERT INTO profile_ids(key) SELECT unnest(ARRAY[
    'org_a','org_b','brand_a','brand_b','brand_foreign','store_a','store_b','store_c','store_off',
    'org_admin','brand_admin','other_brand_admin','manager','employee_a','employee_b',
    'employee_c','off_employee','inactive_target','onboarding','foreign_admin','no_profile','no_read'
]);
CREATE FUNCTION pg_temp.pid(label text) RETURNS uuid LANGUAGE sql STABLE AS $$
    SELECT id FROM pg_temp.profile_ids WHERE key = label
$$;
INSERT INTO public.organizations(id,name)
SELECT id,key FROM profile_ids WHERE key IN ('org_a','org_b');
INSERT INTO public.brands(id,organization_id,name,slug)
SELECT id, pg_temp.pid(CASE WHEN key = 'brand_foreign' THEN 'org_b' ELSE 'org_a' END),
       key, 'profile-test-' || id::text
FROM profile_ids WHERE key IN ('brand_a','brand_b','brand_foreign');
INSERT INTO public.locations(id,brand_id,name,timezone,is_active)
SELECT pg_temp.pid(store),pg_temp.pid(brand),store,'UTC',store <> 'store_off'
FROM (VALUES ('store_a','brand_a'),('store_b','brand_a'),('store_c','brand_b'),('store_off','brand_a')) v(store,brand);
INSERT INTO auth.users(id)
SELECT id FROM profile_ids WHERE key IN (
    'org_admin','brand_admin','other_brand_admin','manager','employee_a','employee_b',
    'employee_c','off_employee','inactive_target','onboarding','foreign_admin','no_profile','no_read'
);
INSERT INTO public.users(id,organization_id,email,full_name,is_active)
SELECT id, pg_temp.pid(CASE WHEN key = 'foreign_admin' THEN 'org_b' ELSE 'org_a' END),
       id::text || '@example.invalid',key,key <> 'inactive_target'
FROM profile_ids WHERE key IN (
    'org_admin','brand_admin','other_brand_admin','manager','employee_a','employee_b',
    'employee_c','off_employee','inactive_target','onboarding','foreign_admin','no_read'
);
INSERT INTO public.user_roles(user_id,organization_id,role_id,role_scope,brand_id)
SELECT pg_temp.pid(actor),pg_temp.pid(org),r.id,r.scope,pg_temp.pid(brand)
FROM (VALUES
    ('org_admin','org_a','org_admin',NULL::text),
    ('brand_admin','org_a','brand_admin','brand_a'),
    ('other_brand_admin','org_a','brand_admin','brand_b'),
    ('foreign_admin','org_b','org_admin',NULL::text)
) v(actor,org,role_key,brand) JOIN public.roles r ON r.key = v.role_key;

-- A scoped assignment without users.read must not open the directory.
INSERT INTO public.roles(key,name,scope) VALUES ('verification_profile_no_read','Test only','location');
INSERT INTO public.role_permissions(role_id,permission_id)
SELECT r.id,p.id FROM public.roles r CROSS JOIN public.permissions p
WHERE r.key = 'verification_profile_no_read' AND p.key = 'locations.read';
INSERT INTO public.user_locations(user_id,organization_id,brand_id,location_id,role_id)
SELECT pg_temp.pid(actor),pg_temp.pid('org_a'),l.brand_id,l.id,r.id
FROM (VALUES
    ('manager','store_a','location_manager'), ('manager','store_b','employee'),
    ('employee_a','store_a','employee'), ('employee_b','store_b','employee'),
    ('employee_c','store_c','employee'), ('off_employee','store_off','employee'),
    ('inactive_target','store_a','employee'), ('no_read','store_a','verification_profile_no_read')
) v(actor,store,role_key)
JOIN public.locations l ON l.id = pg_temp.pid(store)
JOIN public.roles r ON r.key = v.role_key;

CREATE TEMP TABLE profile_results(test text PRIMARY KEY);
CREATE FUNCTION pg_temp.profile_check(ok boolean,label text) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER AS $$ BEGIN
    IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %', label; END IF;
    INSERT INTO pg_temp.profile_results VALUES(label);
END $$;
CREATE FUNCTION pg_temp.expect_profiles(actor text,expected text[],label text) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER AS $$
DECLARE wanted uuid[]; actual uuid[]; helper uuid[];
BEGIN
    IF current_user <> 'operations_hub_runtime' THEN RAISE EXCEPTION 'Must assert as runtime'; END IF;
    PERFORM set_config('app.user_id',COALESCE(pg_temp.pid(actor)::text,''),true);
    SELECT COALESCE(array_agg(pg_temp.pid(x) ORDER BY pg_temp.pid(x)),ARRAY[]::uuid[])
    INTO wanted FROM unnest(expected) t(x);
    -- No fixture-only WHERE: unexpected visibility of ANY local user fails.
    SELECT COALESCE(array_agg(id ORDER BY id),ARRAY[]::uuid[]) INTO actual FROM public.users;
    SELECT COALESCE(array_agg(id ORDER BY id),ARRAY[]::uuid[]) INTO helper
    FROM identity_access.current_readable_user_ids() t(id);
    PERFORM pg_temp.profile_check(actual = wanted AND helper = wanted,label);
END $$;

SELECT pg_temp.profile_check(
    (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.users'::regclass)
    AND (SELECT NOT rolsuper AND NOT rolbypassrls FROM pg_roles WHERE rolname = 'operations_hub_runtime'),
    'Users RLS enabled and runtime cannot bypass it');
SELECT pg_temp.profile_check(
    (SELECT prosecdef AND provolatile = 's' AND proowner = 'operations_hub_auth_reader'::regrole
     AND 'search_path=""' = ANY(proconfig) FROM pg_proc
     WHERE oid = 'identity_access.current_readable_user_ids()'::regprocedure)
    AND NOT pg_has_role('operations_hub_runtime','operations_hub_auth_reader','MEMBER')
    AND NOT pg_has_role('postgres','operations_hub_auth_reader','SET')
    AND NOT has_schema_privilege('operations_hub_auth_reader','identity_access','CREATE'),
    'Helper secured and temporary ownership privileges removed');
DO $$ DECLARE browser_role text; BEGIN
    FOREACH browser_role IN ARRAY ARRAY['anon','authenticated'] LOOP
        PERFORM pg_temp.profile_check(
            NOT has_function_privilege(browser_role,'identity_access.current_readable_user_ids()','EXECUTE')
            AND NOT has_schema_privilege(browser_role,'identity_access','USAGE,CREATE')
            AND NOT has_table_privilege(browser_role,'public.users','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')
            AND NOT has_any_column_privilege(browser_role,'public.users','SELECT,INSERT,UPDATE,REFERENCES'),
            browser_role || ': no profile or helper access');
    END LOOP;
END $$;
GRANT SELECT ON profile_ids TO operations_hub_runtime;
GRANT INSERT ON profile_results TO operations_hub_runtime;
GRANT operations_hub_runtime TO postgres WITH INHERIT FALSE, SET TRUE;
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.profile_check(NOT EXISTS(SELECT 1 FROM public.users),'Missing identity sees nothing');
SELECT set_config('app.user_id','invalid-uuid',true);
SELECT pg_temp.profile_check(NOT EXISTS(SELECT 1 FROM public.users),'Malformed identity sees nothing');
SELECT pg_temp.expect_profiles(NULL,ARRAY[]::text[],'Empty identity sees nothing');
SELECT pg_temp.expect_profiles('no_profile',ARRAY[]::text[],'Auth identity without profile sees nothing');
SELECT pg_temp.expect_profiles('inactive_target',ARRAY[]::text[],'Inactive caller cannot even read self');
SELECT pg_temp.expect_profiles('onboarding',ARRAY['onboarding'],'Active onboarding user reads self without assignments');
SELECT pg_temp.expect_profiles('no_read',ARRAY['no_read'],'Assignment without users.read grants self only');
SELECT pg_temp.expect_profiles('employee_a',ARRAY['employee_a'],'Employee cannot read manager or coworkers');
SELECT pg_temp.expect_profiles('manager',ARRAY['manager','employee_a','inactive_target','no_read'],
    'Manager sees managed store profiles, not coworkers at employee-only store');
SELECT pg_temp.expect_profiles('brand_admin',ARRAY['brand_admin','org_admin','manager','employee_a','employee_b','inactive_target','no_read'],
    'Brand admin sees relevant targets including org admin, excludes other brand and inactive store');
SELECT pg_temp.expect_profiles('other_brand_admin',ARRAY['other_brand_admin','org_admin','employee_c'],
    'Other brand admin has separate directory');
SELECT pg_temp.expect_profiles('org_admin',ARRAY['org_admin','brand_admin','other_brand_admin','manager','employee_a','employee_b',
    'employee_c','off_employee','inactive_target','onboarding','no_read'],
    'Org admin sees own organization including unassigned and inactive profiles');
SELECT pg_temp.expect_profiles('foreign_admin',ARRAY['foreign_admin'],'Other organization remains isolated');
SELECT pg_temp.expect_profiles('employee_a',ARRAY['employee_a'],'Same connection switches back without leaking profiles');
SELECT pg_temp.profile_check(NOT EXISTS(SELECT 1 FROM public.users WHERE id = pg_temp.pid('employee_b')),
    'Explicit forbidden user ID stays invisible');

-- The policy grants reads only. Actual statements must reject writes even to self.
DO $$ BEGIN
    BEGIN
        UPDATE public.users SET full_name = 'Forbidden' WHERE id = pg_temp.pid('employee_a');
        RAISE EXCEPTION 'UPDATE unexpectedly succeeded';
    EXCEPTION WHEN insufficient_privilege THEN PERFORM pg_temp.profile_check(true,'Profile UPDATE denied'); END;
    BEGIN
        DELETE FROM public.users WHERE id = pg_temp.pid('employee_a');
        RAISE EXCEPTION 'DELETE unexpectedly succeeded';
    EXCEPTION WHEN insufficient_privilege THEN PERFORM pg_temp.profile_check(true,'Profile DELETE denied'); END;
    BEGIN
        INSERT INTO public.users(id,organization_id,email,full_name)
        VALUES(pg_temp.pid('no_profile'),pg_temp.pid('org_a'),'test-profile@example.invalid','Forbidden');
        RAISE EXCEPTION 'INSERT unexpectedly succeeded';
    EXCEPTION WHEN insufficient_privilege THEN PERFORM pg_temp.profile_check(true,'Profile INSERT denied'); END;
END $$;
SELECT pg_temp.expect_profiles('brand_admin',ARRAY['brand_admin','org_admin','manager','employee_a','employee_b','inactive_target','no_read'],
    'Brand directory access is separate from assignment scope');
-- Directory visibility must not expose the org admin's organization grant.
SELECT pg_temp.profile_check(
    (SELECT count(*) = 1 FROM public.user_roles)
    AND NOT EXISTS (SELECT 1 FROM public.user_roles
                    WHERE user_id <> pg_temp.pid('brand_admin')),
    'Brand directory access does not expose organization or other-brand roles');
SELECT pg_temp.profile_check(
    (SELECT count(*) = 6 FROM public.user_locations)
    AND NOT EXISTS (SELECT 1 FROM public.user_locations
                    WHERE brand_id <> pg_temp.pid('brand_a')
                       OR location_id = pg_temp.pid('store_off')),
    'Brand assignment reads stay inside active brand locations');

-- Administrative fixture changes are not application write-authorization tests.
RESET ROLE;
UPDATE public.locations SET is_active = false WHERE id = pg_temp.pid('store_a');
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.expect_profiles('manager',ARRAY['manager'],'Inactive managed location removes directory access, retains self');
SELECT pg_temp.expect_profiles('brand_admin',ARRAY['brand_admin','org_admin','manager','employee_b'],
    'Brand admin excludes targets whose only location became inactive');
RESET ROLE;
UPDATE public.brands SET is_active = false WHERE id = pg_temp.pid('brand_a');
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.expect_profiles('brand_admin',ARRAY['brand_admin'],'Inactive brand removes directory access, retains self');
SELECT pg_temp.expect_profiles('manager',ARRAY['manager'],'Inactive brand removes manager directory access');
RESET ROLE;
UPDATE public.brands SET is_active = true WHERE id = pg_temp.pid('brand_a');
UPDATE public.locations SET is_active = true WHERE id = pg_temp.pid('store_a');
UPDATE public.users SET is_active = false WHERE id = pg_temp.pid('manager');
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.expect_profiles('manager',ARRAY[]::text[],'Deactivated manager loses all profile access');
RESET ROLE;
UPDATE public.users SET is_active = true WHERE id = pg_temp.pid('manager');
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.expect_profiles('manager',ARRAY['manager','employee_a','inactive_target','no_read'],'Reactivated manager regains scoped access');
RESET ROLE;
DELETE FROM public.user_locations WHERE user_id = pg_temp.pid('employee_a');
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.expect_profiles('manager',ARRAY['manager','inactive_target','no_read'],'Removing target assignment removes directory visibility');
SELECT pg_temp.expect_profiles('employee_a',ARRAY['employee_a'],'Target retains self access after assignment removal');
RESET ROLE;
DELETE FROM public.user_locations WHERE user_id = pg_temp.pid('manager') AND location_id = pg_temp.pid('store_a');
DELETE FROM public.user_roles WHERE user_id IN (pg_temp.pid('brand_admin'),pg_temp.pid('org_admin'));
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.expect_profiles('manager',ARRAY['manager'],'Revoked manager assignment leaves employee self-only access');
SELECT pg_temp.expect_profiles('brand_admin',ARRAY['brand_admin'],'Revoked brand grant leaves self access');
SELECT pg_temp.expect_profiles('org_admin',ARRAY['org_admin'],'Revoked org grant leaves self access');
RESET ROLE;
SELECT 'PASS: ' || test AS result FROM profile_results ORDER BY test;
SELECT count(*) AS passed_checks FROM profile_results;
ROLLBACK;
