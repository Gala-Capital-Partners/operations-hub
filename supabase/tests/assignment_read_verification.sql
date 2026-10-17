-- LOCAL Supabase, after migrations 1-7. Run the entire file as postgres.
-- psql <local-connection> -X -v ON_ERROR_STOP=1 -f <this-file>
-- Exact assignment sets are checked as runtime. Setup uses postgres.
-- Every fixture, catalog edit and temporary role grant rolls back.
-- If SQL Editor reports an error, stop and ROLLBACK before retrying.
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


-- Same target user has assignments in two brands; visibility of one must not
-- expose the other. This catches policies matching only the user_id half.
INSERT INTO public.user_locations(user_id,organization_id,brand_id,location_id,role_id)
SELECT pg_temp.pid('employee_a'),pg_temp.pid('org_a'),pg_temp.pid('brand_b'),
       pg_temp.pid('store_c'),id FROM public.roles WHERE key = 'employee';
CREATE TEMP TABLE role_fixture_ids AS
SELECT f.key,ur.id FROM pg_temp.profile_ids f JOIN public.user_roles ur ON ur.user_id = f.id;
CREATE TEMP TABLE assignment_results(test text PRIMARY KEY);
CREATE FUNCTION pg_temp.assignment_check(ok boolean,label text) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER AS $$ BEGIN
    IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %',label; END IF;
    INSERT INTO pg_temp.assignment_results VALUES(label);
END $$;
CREATE FUNCTION pg_temp.expect_assignments(actor text,role_actors text[],location_pairs text[],label text)
RETURNS void LANGUAGE plpgsql SECURITY INVOKER AS $$
DECLARE wanted_roles uuid[]; actual_roles uuid[]; helper_roles uuid[];
        wanted_locations text[]; actual_locations text[]; helper_locations text[];
BEGIN
    IF current_user <> 'operations_hub_runtime' THEN RAISE EXCEPTION 'Test requires runtime'; END IF;
    PERFORM set_config('app.user_id',COALESCE(pg_temp.pid(actor)::text,''),true);
    SELECT COALESCE(array_agg(f.id ORDER BY f.id),ARRAY[]::uuid[]) INTO wanted_roles
    FROM unnest(role_actors) t(key) JOIN pg_temp.role_fixture_ids f USING(key);
    IF cardinality(wanted_roles) <> cardinality(role_actors) THEN
        RAISE EXCEPTION 'Unknown expected role fixture';
    END IF;
    SELECT COALESCE(array_agg(id ORDER BY id),ARRAY[]::uuid[]) INTO actual_roles FROM public.user_roles;
    SELECT COALESCE(array_agg(id ORDER BY id),ARRAY[]::uuid[]) INTO helper_roles
    FROM identity_access.current_readable_user_role_ids() t(id);
    SELECT COALESCE(array_agg(pair ORDER BY pair),ARRAY[]::text[]) INTO wanted_locations
    FROM (SELECT pg_temp.pid(split_part(x,'/',1))::text || '/' ||
                 pg_temp.pid(split_part(x,'/',2))::text AS pair
          FROM unnest(location_pairs) t(x)) pairs;
    SELECT COALESCE(array_agg(pair ORDER BY pair),ARRAY[]::text[]) INTO actual_locations
    FROM (SELECT user_id::text || '/' || location_id::text AS pair FROM public.user_locations) pairs;
    SELECT COALESCE(array_agg(pair ORDER BY pair),ARRAY[]::text[]) INTO helper_locations
    FROM (SELECT user_id::text || '/' || location_id::text AS pair
          FROM identity_access.current_readable_user_location_keys()) pairs;
    PERFORM pg_temp.assignment_check(
        actual_roles = wanted_roles AND helper_roles = wanted_roles
        AND actual_locations = wanted_locations AND helper_locations = wanted_locations,label);
END $$;
DO $$ DECLARE fn text; browser_role text; table_name text; BEGIN
    FOREACH fn IN ARRAY ARRAY['identity_access.current_readable_user_role_ids()',
                             'identity_access.current_readable_user_location_keys()'] LOOP
        PERFORM pg_temp.assignment_check(
            (SELECT prosecdef AND provolatile = 's' AND proowner = 'operations_hub_auth_reader'::regrole
             AND 'search_path=""' = ANY(proconfig) FROM pg_proc WHERE oid = fn::regprocedure)
            AND has_function_privilege('operations_hub_runtime',fn,'EXECUTE'),
            'Secured helper: ' || fn);
        FOREACH browser_role IN ARRAY ARRAY['anon','authenticated'] LOOP
            PERFORM pg_temp.assignment_check(NOT has_function_privilege(browser_role,fn,'EXECUTE'),
                browser_role || ' denied helper: ' || fn);
        END LOOP;
    END LOOP;
    FOREACH table_name IN ARRAY ARRAY['user_roles','user_locations'] LOOP
        PERFORM pg_temp.assignment_check(
            (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || table_name)::regclass)
            AND has_table_privilege('operations_hub_runtime','public.' || table_name,'SELECT')
            AND NOT has_table_privilege('operations_hub_runtime','public.' || table_name,
                'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')
            AND NOT has_any_column_privilege('operations_hub_runtime','public.' || table_name,
                'INSERT,UPDATE,REFERENCES'), 'Read-only RLS table: ' || table_name);
        FOREACH browser_role IN ARRAY ARRAY['anon','authenticated'] LOOP
            PERFORM pg_temp.assignment_check(
                NOT has_table_privilege(browser_role,'public.' || table_name,
                    'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')
                AND NOT has_any_column_privilege(browser_role,'public.' || table_name,
                    'SELECT,INSERT,UPDATE,REFERENCES'),browser_role || ' denied table: ' || table_name);
        END LOOP;
    END LOOP;
END $$;
SELECT pg_temp.assignment_check(
    NOT pg_has_role('operations_hub_runtime','operations_hub_auth_reader','MEMBER')
    AND NOT pg_has_role('postgres','operations_hub_auth_reader','SET')
    AND NOT has_schema_privilege('operations_hub_auth_reader','identity_access','CREATE')
    AND (SELECT NOT rolsuper AND NOT rolbypassrls FROM pg_roles WHERE rolname = 'operations_hub_runtime'),
    'No runtime bypass or temporary helper privileges');
GRANT SELECT ON profile_ids,role_fixture_ids TO operations_hub_runtime;
GRANT INSERT ON assignment_results TO operations_hub_runtime;
GRANT operations_hub_runtime TO postgres WITH INHERIT FALSE, SET TRUE;
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.assignment_check(
    NOT EXISTS(SELECT 1 FROM public.user_roles) AND NOT EXISTS(SELECT 1 FROM public.user_locations),
    'Missing identity sees no assignments');
SELECT set_config('app.user_id','invalid-uuid',true);
SELECT pg_temp.assignment_check(
    NOT EXISTS(SELECT 1 FROM public.user_roles) AND NOT EXISTS(SELECT 1 FROM public.user_locations),
    'Malformed identity sees no assignments');
SELECT pg_temp.expect_assignments(NULL,ARRAY[]::text[],ARRAY[]::text[],'Empty identity sees nothing');
SELECT pg_temp.expect_assignments('inactive_target',ARRAY[]::text[],ARRAY[]::text[],'Inactive caller cannot read own assignments');
SELECT pg_temp.expect_assignments('no_profile',ARRAY[]::text[],ARRAY[]::text[],'Auth identity without profile sees nothing');
SELECT pg_temp.expect_assignments('onboarding',ARRAY[]::text[],ARRAY[]::text[],'Onboarding user has no assignments');
SELECT pg_temp.expect_assignments('no_read',ARRAY[]::text[],ARRAY['no_read/store_a']::text[],'Own assignment available without assignment-read permission');
SELECT pg_temp.expect_assignments('employee_a',ARRAY[]::text[],ARRAY['employee_a/store_a','employee_a/store_c']::text[],'Employee reads only own assignments across brands');
SELECT pg_temp.expect_assignments('off_employee',ARRAY[]::text[],ARRAY['off_employee/store_off']::text[],'Own assignment remains visible at inactive location');
SELECT pg_temp.expect_assignments('manager',ARRAY[]::text[],ARRAY['manager/store_a','manager/store_b','employee_a/store_a','inactive_target/store_a','no_read/store_a']::text[],'Manager sees store A and own B only; target other-brand assignment hidden');
SELECT pg_temp.expect_assignments('brand_admin',ARRAY['brand_admin']::text[],ARRAY['manager/store_a','manager/store_b','employee_a/store_a','employee_b/store_b','inactive_target/store_a','no_read/store_a']::text[],'Brand admin sees own-brand assignments but not org assignments');
SELECT pg_temp.expect_assignments('other_brand_admin',ARRAY['other_brand_admin']::text[],ARRAY['employee_c/store_c','employee_a/store_c']::text[],'Other brand assignments isolated');
SELECT pg_temp.expect_assignments('org_admin',ARRAY['org_admin','brand_admin','other_brand_admin']::text[],ARRAY['manager/store_a','manager/store_b','employee_a/store_a','employee_b/store_b','inactive_target/store_a','no_read/store_a','employee_c/store_c','employee_a/store_c']::text[],'Org admin sees own org assignments on active targets');
SELECT pg_temp.expect_assignments('foreign_admin',ARRAY['foreign_admin']::text[],ARRAY[]::text[],'Foreign org admin cannot see other organization');
SELECT pg_temp.expect_assignments('employee_a',ARRAY[]::text[],ARRAY['employee_a/store_a','employee_a/store_c']::text[],'Same connection switches back without leaks');

-- Execute forbidden writes to existing visible rows. The exception caught is
-- only insufficient_privilege: constraint errors cannot produce a false PASS.
DO $$ DECLARE table_name text; operation text; BEGIN
    FOREACH table_name IN ARRAY ARRAY['user_roles','user_locations'] LOOP
        FOREACH operation IN ARRAY ARRAY['INSERT','UPDATE','DELETE'] LOOP
            BEGIN
                IF operation = 'INSERT' THEN
                    EXECUTE format('INSERT INTO public.%I SELECT * FROM public.%I LIMIT 1',table_name,table_name);
                ELSIF operation = 'UPDATE' THEN
                    EXECUTE format('UPDATE public.%I SET user_id = user_id',table_name);
                ELSE
                    EXECUTE format('DELETE FROM public.%I',table_name);
                END IF;
                RAISE EXCEPTION 'Unexpected write success';
            EXCEPTION WHEN insufficient_privilege THEN
                PERFORM pg_temp.assignment_check(true,operation || ' denied on ' || table_name);
            END;
        END LOOP;
    END LOOP;
END $$;
RESET ROLE;
UPDATE public.locations SET is_active = false WHERE id = pg_temp.pid('store_a');
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.expect_assignments('manager',ARRAY[]::text[],ARRAY['manager/store_a','manager/store_b']::text[],'Inactive managed store hides other users but preserves own assignment');
SELECT pg_temp.expect_assignments('brand_admin',ARRAY['brand_admin']::text[],ARRAY['manager/store_b','employee_b/store_b']::text[],'Inactive location removes target assignments from brand reads');
RESET ROLE;
UPDATE public.brands SET is_active = false WHERE id = pg_temp.pid('brand_a');
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.expect_assignments('brand_admin',ARRAY['brand_admin']::text[],ARRAY[]::text[],'Inactive brand retains own brand assignment only');
SELECT pg_temp.expect_assignments('org_admin',ARRAY['org_admin','other_brand_admin']::text[],ARRAY['employee_c/store_c','employee_a/store_c']::text[],'Inactive brand targets hidden even from org admin');
SELECT pg_temp.expect_assignments('employee_a',ARRAY[]::text[],ARRAY['employee_a/store_a','employee_a/store_c']::text[],'Employee can inspect own assignments despite inactive targets');
RESET ROLE;
UPDATE public.brands SET is_active = true WHERE id = pg_temp.pid('brand_a');
UPDATE public.locations SET is_active = true WHERE id = pg_temp.pid('store_a');
UPDATE public.users SET is_active = false WHERE id = pg_temp.pid('manager');
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.expect_assignments('manager',ARRAY[]::text[],ARRAY[]::text[],'Deactivated manager sees nothing');
RESET ROLE;
UPDATE public.users SET is_active = true WHERE id = pg_temp.pid('manager');
DELETE FROM public.user_locations WHERE user_id = pg_temp.pid('manager') AND location_id = pg_temp.pid('store_a');
DELETE FROM public.user_roles WHERE user_id = pg_temp.pid('brand_admin');
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.expect_assignments('manager',ARRAY[]::text[],ARRAY['manager/store_b']::text[],'Revoked manager role leaves own employee assignment only');
SELECT pg_temp.expect_assignments('brand_admin',ARRAY[]::text[],ARRAY[]::text[],'Revoked brand role removes assignment access');
RESET ROLE;
SELECT 'PASS: ' || test AS result FROM assignment_results ORDER BY test;
SELECT count(*) AS passed_checks FROM assignment_results;
ROLLBACK;
