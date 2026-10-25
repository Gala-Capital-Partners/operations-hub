-- LOCAL Supabase after migrations 1-8. Run as postgres, in one connection.
-- psql <local-connection> -X -v ON_ERROR_STOP=1 -f <this-file>
-- Setup uses postgres; visibility assertions use operations_hub_runtime.
-- Expected directory sets are explicit; catalog snapshots verify full shared
-- visibility, not catalog correctness (checked separately in identity_access).
-- All fixtures, catalog edits and temporary role grants roll back.
-- On SQL Editor error, stop and ROLLBACK before retrying.
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

-- Org assignment should include active brands even before any stores exist.
INSERT INTO profile_ids(key) VALUES ('brand_empty'),('brand_disabled'),('unknown_identity');
INSERT INTO public.brands(id,organization_id,name,slug,is_active)
SELECT id,pg_temp.pid('org_a'),key,'directory-test-' || id::text,key <> 'brand_disabled'
FROM profile_ids WHERE key IN ('brand_empty','brand_disabled');
-- Multiple direct brand assignments and overlapping location grants.
INSERT INTO public.user_roles(user_id,organization_id,role_id,role_scope,brand_id)
SELECT pg_temp.pid('brand_admin'),pg_temp.pid('org_a'),id,scope,pg_temp.pid('brand_b')
FROM public.roles WHERE key = 'brand_admin';
INSERT INTO public.user_locations(user_id,organization_id,brand_id,location_id,role_id)
SELECT pg_temp.pid('brand_admin'),pg_temp.pid('org_a'),pg_temp.pid('brand_a'),pg_temp.pid('store_a'),id
FROM public.roles WHERE key = 'employee';
CREATE TEMP TABLE directory_catalog_snapshot AS
SELECT 'roles'::text AS kind,id::text AS key FROM public.roles
UNION ALL SELECT 'permissions',id::text FROM public.permissions
UNION ALL SELECT 'role_permissions',role_id::text || '/' || permission_id::text FROM public.role_permissions;
CREATE TEMP TABLE directory_results(test text PRIMARY KEY);
CREATE FUNCTION pg_temp.directory_check(ok boolean,label text) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER AS $$ BEGIN
    IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %',label; END IF;
    INSERT INTO pg_temp.directory_results VALUES(label);
END $$;
CREATE FUNCTION pg_temp.expect_directory(actor text,org text,brands text[],catalog boolean,label text)
RETURNS void LANGUAGE plpgsql SECURITY INVOKER AS $$
DECLARE wanted_org uuid[]; actual_org uuid[]; wanted_brands uuid[];
        actual_brands uuid[]; helper_brands uuid[]; table_name text;
        wanted_catalog text[]; actual_catalog text[];
BEGIN
    IF current_user <> 'operations_hub_runtime' THEN RAISE EXCEPTION 'Assertions must run as runtime'; END IF;
    PERFORM set_config('app.user_id',COALESCE(pg_temp.pid(actor)::text,''),true);
    wanted_org := CASE WHEN org IS NULL THEN ARRAY[]::uuid[] ELSE ARRAY[pg_temp.pid(org)] END;
    SELECT COALESCE(array_agg(id ORDER BY id),ARRAY[]::uuid[]) INTO actual_org FROM public.organizations;
    SELECT COALESCE(array_agg(pg_temp.pid(x) ORDER BY pg_temp.pid(x)),ARRAY[]::uuid[])
    INTO wanted_brands FROM unnest(brands) t(x);
    SELECT COALESCE(array_agg(id ORDER BY id),ARRAY[]::uuid[]) INTO actual_brands FROM public.brands;
    SELECT COALESCE(array_agg(id ORDER BY id),ARRAY[]::uuid[]) INTO helper_brands
    FROM identity_access.current_user_brand_ids() t(id);
    PERFORM pg_temp.directory_check(actual_org = wanted_org
        AND identity_access.current_user_organization_id() IS NOT DISTINCT FROM pg_temp.pid(org)
        AND actual_brands = wanted_brands AND helper_brands = wanted_brands,label || ': directory');
    FOREACH table_name IN ARRAY ARRAY['roles','permissions','role_permissions'] LOOP
        SELECT COALESCE(array_agg(key ORDER BY key),ARRAY[]::text[]) INTO wanted_catalog
        FROM pg_temp.directory_catalog_snapshot WHERE kind = table_name AND catalog;
        IF table_name = 'role_permissions' THEN
            SELECT COALESCE(array_agg(role_id::text || '/' || permission_id::text
                ORDER BY role_id::text || '/' || permission_id::text),ARRAY[]::text[])
            INTO actual_catalog FROM public.role_permissions;
        ELSE
            EXECUTE format('SELECT COALESCE(array_agg(id::text ORDER BY id::text),ARRAY[]::text[]) FROM public.%I',table_name)
            INTO actual_catalog;
        END IF;
        PERFORM pg_temp.directory_check(actual_catalog = wanted_catalog,label || ': ' || table_name);
    END LOOP;
END $$;

-- Check function ownership, runtime permissions and browser-role exclusion.
DO $$ DECLARE fn text; browser_role text; table_name text; BEGIN
    FOREACH fn IN ARRAY ARRAY['identity_access.current_user_organization_id()',
                             'identity_access.current_user_brand_ids()'] LOOP
        PERFORM pg_temp.directory_check(
            (SELECT prosecdef AND provolatile = 's' AND proowner = 'operations_hub_auth_reader'::regrole
             AND 'search_path=""' = ANY(proconfig) FROM pg_proc WHERE oid = fn::regprocedure)
            AND has_function_privilege('operations_hub_runtime',fn,'EXECUTE'), 'Secured helper: ' || fn);
        FOREACH browser_role IN ARRAY ARRAY['anon','authenticated'] LOOP
            PERFORM pg_temp.directory_check(NOT has_function_privilege(browser_role,fn,'EXECUTE')
                AND NOT has_schema_privilege(browser_role,'identity_access','USAGE,CREATE'),
                browser_role || ' denied helper: ' || fn);
        END LOOP;
    END LOOP;
    FOREACH table_name IN ARRAY ARRAY['organizations','brands','roles','permissions','role_permissions'] LOOP
        PERFORM pg_temp.directory_check(
            (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || table_name)::regclass)
            AND has_table_privilege('operations_hub_runtime','public.' || table_name,'SELECT')
            AND NOT has_table_privilege('operations_hub_runtime','public.' || table_name,
                'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')
            AND NOT has_any_column_privilege('operations_hub_runtime','public.' || table_name,
                'INSERT,UPDATE,REFERENCES'), 'Runtime read-only RLS: ' || table_name);
        FOREACH browser_role IN ARRAY ARRAY['anon','authenticated'] LOOP
            PERFORM pg_temp.directory_check(
                NOT has_table_privilege(browser_role,'public.' || table_name,
                    'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')
                AND NOT has_any_column_privilege(browser_role,'public.' || table_name,
                    'SELECT,INSERT,UPDATE,REFERENCES'),browser_role || ' denied table: ' || table_name);
        END LOOP;
    END LOOP;
END $$;
SELECT pg_temp.directory_check(
    NOT pg_has_role('operations_hub_runtime','operations_hub_auth_reader','MEMBER')
    AND NOT pg_has_role('postgres','operations_hub_auth_reader','SET')
    AND NOT has_schema_privilege('operations_hub_auth_reader','identity_access','CREATE')
    AND (SELECT NOT rolsuper AND NOT rolbypassrls FROM pg_roles WHERE rolname = 'operations_hub_runtime'),
    'Runtime cannot bypass RLS; temporary helper privileges removed');
GRANT SELECT ON profile_ids,directory_catalog_snapshot TO operations_hub_runtime;
GRANT INSERT ON directory_results TO operations_hub_runtime;
GRANT operations_hub_runtime TO postgres WITH INHERIT FALSE, SET TRUE;
SET LOCAL ROLE operations_hub_runtime;
DO $$ DECLARE table_name text; visible_rows bigint; BEGIN
    FOREACH table_name IN ARRAY ARRAY['organizations','brands','roles','permissions','role_permissions'] LOOP
        EXECUTE format('SELECT count(*) FROM public.%I',table_name) INTO visible_rows;
        PERFORM pg_temp.directory_check(visible_rows = 0,'Missing identity: ' || table_name);
    END LOOP;
    PERFORM set_config('app.user_id','bad-uuid',true);
    FOREACH table_name IN ARRAY ARRAY['organizations','brands','roles','permissions','role_permissions'] LOOP
        EXECUTE format('SELECT count(*) FROM public.%I',table_name) INTO visible_rows;
        PERFORM pg_temp.directory_check(visible_rows = 0,'Malformed identity: ' || table_name);
    END LOOP;
END $$;
SELECT pg_temp.expect_directory(NULL,NULL,ARRAY[]::text[],false,'Empty identity');
SELECT pg_temp.expect_directory('unknown_identity',NULL,ARRAY[]::text[],false,'Unknown UUID');
SELECT pg_temp.expect_directory('no_profile',NULL,ARRAY[]::text[],false,'Auth user without profile');
SELECT pg_temp.expect_directory('inactive_target',NULL,ARRAY[]::text[],false,'Inactive caller');
SELECT pg_temp.expect_directory('onboarding','org_a',ARRAY[]::text[],true,'Onboarding reads own org and full catalog only');
SELECT pg_temp.expect_directory('org_admin','org_a',ARRAY['brand_a','brand_b','brand_empty']::text[],true,'Org admin active brands including empty brand');
SELECT pg_temp.expect_directory('brand_admin','org_a',ARRAY['brand_a','brand_b']::text[],true,'Multiple brand assignments with overlap return no duplicates');
SELECT pg_temp.expect_directory('manager','org_a',ARRAY['brand_a']::text[],true,'Multiple locations deduplicate parent brand');
SELECT pg_temp.expect_directory('employee_a','org_a',ARRAY['brand_a','brand_b']::text[],true,'Employee assigned across brands');
SELECT pg_temp.expect_directory('off_employee','org_a',ARRAY[]::text[],true,'Only inactive location gives no brand discovery');
SELECT pg_temp.expect_directory('no_read','org_a',ARRAY['brand_a']::text[],true,'Discovery follows assignment not users.read');
SELECT pg_temp.expect_directory('foreign_admin','org_b',ARRAY['brand_foreign']::text[],true,'Foreign organization isolated');
SELECT pg_temp.expect_directory('employee_b','org_a',ARRAY['brand_a']::text[],true,'Switch back to original organization');

-- Discovery and catalog access must not expand operational authority.
SELECT pg_temp.directory_check(
    (SELECT count(*) = 1 FROM public.locations)
    AND NOT EXISTS(SELECT 1 FROM public.locations WHERE id <> pg_temp.pid('store_b')),
    'Brand discovery does not expose sibling stores');
SELECT pg_temp.directory_check(
    NOT EXISTS(SELECT 1 FROM identity_access.current_user_permissions() WHERE permission_key = 'role_assignments.manage'),
    'Reading org_admin definition does not grant management permission');

-- Actual write attempts must fail with insufficient_privilege, not constraints.
DO $$ DECLARE table_name text; operation text; column_name text; BEGIN
    FOREACH table_name IN ARRAY ARRAY['organizations','brands','roles','permissions','role_permissions'] LOOP
        column_name := CASE WHEN table_name = 'role_permissions' THEN 'role_id' ELSE 'id' END;
        FOREACH operation IN ARRAY ARRAY['INSERT','UPDATE','DELETE'] LOOP
            BEGIN
                IF operation = 'INSERT' THEN
                    EXECUTE format('INSERT INTO public.%I SELECT * FROM public.%I LIMIT 1',table_name,table_name);
                ELSIF operation = 'UPDATE' THEN
                    EXECUTE format('UPDATE public.%I SET %I = %I',table_name,column_name,column_name);
                ELSE EXECUTE format('DELETE FROM public.%I',table_name);
                END IF;
                RAISE EXCEPTION 'Unexpected write success';
            EXCEPTION WHEN insufficient_privilege THEN
                PERFORM pg_temp.directory_check(true,operation || ' denied on ' || table_name);
            END;
        END LOOP;
    END LOOP;
END $$;
RESET ROLE;
UPDATE public.locations SET is_active = false WHERE id IN (pg_temp.pid('store_a'),pg_temp.pid('store_b'));
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.expect_directory('manager','org_a',ARRAY[]::text[],true,'All assigned locations inactive');
SELECT pg_temp.expect_directory('brand_admin','org_a',ARRAY['brand_a','brand_b']::text[],true,'Direct brand role survives inactive locations');
RESET ROLE;
UPDATE public.brands SET is_active = false WHERE id = pg_temp.pid('brand_a');
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.expect_directory('org_admin','org_a',ARRAY['brand_b','brand_empty']::text[],true,'Org role excludes deactivated brand');
SELECT pg_temp.expect_directory('brand_admin','org_a',ARRAY['brand_b']::text[],true,'Brand role excludes deactivated brand');
SELECT pg_temp.expect_directory('employee_a','org_a',ARRAY['brand_b']::text[],true,'Location role excludes deactivated parent brand');
RESET ROLE;
UPDATE public.brands SET is_active = true WHERE id = pg_temp.pid('brand_a');
UPDATE public.locations SET is_active = true WHERE id IN (pg_temp.pid('store_a'),pg_temp.pid('store_b'));
UPDATE public.users SET is_active = false WHERE id = pg_temp.pid('brand_admin');
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.expect_directory('brand_admin',NULL,ARRAY[]::text[],false,'Deactivated caller loses directory and catalog');
RESET ROLE;
UPDATE public.users SET is_active = true WHERE id = pg_temp.pid('brand_admin');
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.expect_directory('brand_admin','org_a',ARRAY['brand_a','brand_b']::text[],true,'Reactivated caller restores reads');
RESET ROLE;
DELETE FROM public.user_roles WHERE user_id = pg_temp.pid('brand_admin');
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.expect_directory('brand_admin','org_a',ARRAY['brand_a']::text[],true,'Location assignment survives brand-role revocation');
RESET ROLE;
DELETE FROM public.user_locations WHERE user_id = pg_temp.pid('brand_admin');
DELETE FROM public.user_roles WHERE user_id = pg_temp.pid('org_admin');
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.expect_directory('brand_admin','org_a',ARRAY[]::text[],true,'All grants revoked retains own org and catalog');
SELECT pg_temp.expect_directory('org_admin','org_a',ARRAY[]::text[],true,'Org assignment revoked removes brand discovery');
RESET ROLE;
SELECT 'PASS: ' || test AS result FROM directory_results ORDER BY test;
SELECT count(*) AS passed_checks FROM directory_results;
ROLLBACK;
