-- LOCAL Supabase after migrations 1-9, as postgres, one connection.
-- psql <local-connection> -X -v ON_ERROR_STOP=1 -f <this-file>
-- Each operation executes as runtime; postgres checks resulting rows and audit.
-- Expected failures must preserve both assignments and audit history.
-- All data and temporary memberships roll back. Stop on any error.
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

CREATE TEMP TABLE write_results(test text PRIMARY KEY);
CREATE FUNCTION pg_temp.wcheck(ok boolean,label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %',label; END IF;
 INSERT INTO pg_temp.write_results VALUES(label);
END $$;

-- Validate configuration before granting test-only SET access.
SELECT pg_temp.wcheck(
 (SELECT NOT rolcanlogin AND NOT rolsuper AND NOT rolbypassrls AND NOT rolcreatedb
  AND NOT rolcreaterole AND NOT rolinherit AND NOT rolreplication
  FROM pg_roles WHERE rolname='operations_hub_assignment_writer')
 AND NOT pg_has_role('operations_hub_runtime','operations_hub_assignment_writer','MEMBER')
 AND NOT pg_has_role('postgres','operations_hub_assignment_writer','SET')
 AND NOT has_schema_privilege('operations_hub_assignment_writer','identity_access','CREATE'),
 'Writer restricted; runtime cannot become writer; temporary privileges removed');
DO $$ DECLARE fn text; role_name text; BEGIN
 FOREACH fn IN ARRAY ARRAY[
 'identity_access.set_location_assignment(uuid,uuid,uuid,uuid)',
 'identity_access.revoke_location_assignment(uuid,uuid,uuid)'] LOOP
  PERFORM pg_temp.wcheck(
   (SELECT prosecdef AND provolatile='v' AND proowner='operations_hub_assignment_writer'::regrole
    AND 'search_path=""'=ANY(proconfig) FROM pg_proc WHERE oid=fn::regprocedure)
   AND has_function_privilege('operations_hub_runtime',fn,'EXECUTE'), 'Entry point security: '||fn);
  FOREACH role_name IN ARRAY ARRAY['anon','authenticated'] LOOP
   PERFORM pg_temp.wcheck(NOT has_function_privilege(role_name,fn,'EXECUTE'),role_name||' cannot call '||fn);
  END LOOP;
 END LOOP;
 FOREACH fn IN ARRAY ARRAY[
 'identity_access.can_manage_location_assignment(uuid,uuid,uuid)',
 'identity_access.location_assignment_target(uuid,uuid)',
 'identity_access.lock_assignment_organization()'] LOOP
  PERFORM pg_temp.wcheck(NOT has_function_privilege('operations_hub_runtime',fn,'EXECUTE')
   AND has_function_privilege('operations_hub_assignment_writer',fn,'EXECUTE'), 'Internal helper restricted: '||fn);
 END LOOP;
 FOREACH role_name IN ARRAY ARRAY['operations_hub_runtime','anon','authenticated'] LOOP
  PERFORM pg_temp.wcheck(NOT has_table_privilege(role_name,'identity_access.assignment_audit_log',
   'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')
   AND NOT has_any_column_privilege(role_name,'identity_access.assignment_audit_log','SELECT,INSERT,UPDATE,REFERENCES'),
   role_name||' has no direct audit access');
 END LOOP;
 PERFORM pg_temp.wcheck(has_table_privilege('operations_hub_assignment_writer','identity_access.assignment_audit_log','INSERT')
  AND NOT has_table_privilege('operations_hub_assignment_writer','identity_access.assignment_audit_log',
   'SELECT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'), 'Writer audit access is insert-only');
END $$;
GRANT operations_hub_runtime TO postgres WITH INHERIT FALSE, SET TRUE;

-- Test harness is SECURITY INVOKER. Switching to runtime exercises exactly
-- the application entry point; checks after RESET ROLE can inspect audit rows.
CREATE FUNCTION pg_temp.try_assignment(actor text,target text,loc text,role_key text,
 operation text,expected text,label text,missing_request boolean DEFAULT false,
 expected_message text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY INVOKER AS $$
DECLARE actor_id uuid:=pg_temp.pid(actor); target_id uuid:=pg_temp.pid(target);
 loc_id uuid:=pg_temp.pid(loc); requested_role uuid; req uuid:=gen_random_uuid();
 result text; err text; err_message text;
 before_rows jsonb; before_audit jsonb; after_rows jsonb; after_audit jsonb;
 old_role uuid; actual_role uuid; audit_row identity_access.assignment_audit_log%ROWTYPE;
 audit_count bigint;
BEGIN
 IF current_user <> 'postgres' THEN RAISE EXCEPTION 'Harness requires postgres'; END IF;
 SELECT id INTO requested_role FROM public.roles WHERE key=role_key;
 SELECT role_id INTO old_role FROM public.user_locations WHERE user_id=target_id AND location_id=loc_id;
 SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY user_id,location_id),'[]') INTO before_rows FROM public.user_locations t;
 SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') INTO before_audit FROM identity_access.assignment_audit_log t;
 PERFORM set_config('app.user_id',CASE WHEN actor='malformed' THEN 'not-a-uuid' ELSE COALESCE(actor_id::text,'') END,true);
 EXECUTE 'SET LOCAL ROLE operations_hub_runtime';
 BEGIN
  IF operation='set' THEN
   result:=identity_access.set_location_assignment(target_id,loc_id,requested_role,
     CASE WHEN missing_request THEN NULL ELSE req END);
  ELSE
   result:=identity_access.revoke_location_assignment(target_id,loc_id,
     CASE WHEN missing_request THEN NULL ELSE req END);
  END IF;
 EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS err=RETURNED_SQLSTATE, err_message=MESSAGE_TEXT;
 END;
 EXECUTE 'RESET ROLE';
 IF expected IN ('granted','replaced','unchanged','revoked') THEN
  PERFORM pg_temp.wcheck(err IS NULL AND result=expected,label||': result');
  SELECT role_id INTO actual_role FROM public.user_locations WHERE user_id=target_id AND location_id=loc_id;
  PERFORM pg_temp.wcheck(actual_role IS NOT DISTINCT FROM
    CASE WHEN expected='revoked' THEN NULL::uuid ELSE requested_role END,label||': assignment');
  SELECT count(*) INTO audit_count FROM identity_access.assignment_audit_log WHERE request_id=req;
  IF expected='unchanged' THEN
   SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY user_id,location_id),'[]') INTO after_rows FROM public.user_locations t;
   SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') INTO after_audit FROM identity_access.assignment_audit_log t;
   PERFORM pg_temp.wcheck(before_rows=after_rows AND before_audit=after_audit,label||': no-op preserves rows and audit');
  ELSE
   SELECT * INTO audit_row FROM identity_access.assignment_audit_log WHERE request_id=req;
   PERFORM pg_temp.wcheck(audit_count=1 AND audit_row.actor_user_id=actor_id
    AND audit_row.target_user_id=target_id AND audit_row.location_id=loc_id
    AND audit_row.organization_id=(SELECT organization_id FROM public.users WHERE id=target_id)
    AND audit_row.old_role_id IS NOT DISTINCT FROM old_role
    AND audit_row.new_role_id IS NOT DISTINCT FROM actual_role
    AND audit_row.action=CASE expected WHEN 'granted' THEN 'grant' WHEN 'replaced' THEN 'replace' ELSE 'revoke' END,
    label||': exact audit record');
  END IF;
 ELSE
  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY user_id,location_id),'[]') INTO after_rows FROM public.user_locations t;
  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') INTO after_audit FROM identity_access.assignment_audit_log t;
  PERFORM pg_temp.wcheck(err=expected,label||': expected SQLSTATE '||expected);
  IF expected_message IS NOT NULL THEN
   PERFORM pg_temp.wcheck(err_message=expected_message,label||': expected error message');
  END IF;
  PERFORM pg_temp.wcheck(before_rows=after_rows AND before_audit=after_audit,label||': no partial change');
 END IF;
END $$;

-- Regression: SQLSTATE alone did not catch the target-existence disclosure.
-- For both an employee and an active unassigned caller, hidden existing,
-- missing, and cross-organization targets must produce the SAME message.
-- The harness also verifies that every rejected call leaves rows/audit intact.
INSERT INTO profile_ids(key) VALUES ('missing_user'),('missing_store'),('foreign_store');
INSERT INTO public.locations(id,brand_id,name,timezone)
VALUES (pg_temp.pid('foreign_store'),pg_temp.pid('brand_foreign'),'Foreign test store','UTC');
DO $$ DECLARE caller text; target_case record; BEGIN
 FOREACH caller IN ARRAY ARRAY['employee_a','onboarding'] LOOP
  FOR target_case IN SELECT * FROM (VALUES
   ('employee_c','store_c','existing hidden pair'),
   ('missing_user','store_c','missing user'),
   ('employee_c','missing_store','missing location'),
   ('missing_user','missing_store','both missing'),
   ('foreign_admin','store_c','foreign user'),
   ('employee_c','foreign_store','foreign location'),
   ('foreign_admin','foreign_store','existing foreign pair')
  ) AS cases(target_user,target_location,description) LOOP
   PERFORM pg_temp.try_assignment(caller,target_case.target_user,
    target_case.target_location,'employee','set','42501',
    'No existence disclosure: '||caller||' / '||target_case.description,
    false,'Assignment change is not authorized');
  END LOOP;
 END LOOP;
END $$;

SELECT pg_temp.try_assignment(NULL,'onboarding','store_a','employee','set','42501','Missing actor');
SELECT pg_temp.try_assignment('malformed','onboarding','store_a','employee','set','42501','Malformed actor');
SELECT pg_temp.try_assignment('no_profile','onboarding','store_a','employee','set','42501','No profile');
SELECT pg_temp.try_assignment('inactive_target','onboarding','store_a','employee','set','42501','Inactive actor');
SELECT pg_temp.try_assignment('employee_a','onboarding','store_a','employee','set','42501','Employee cannot grant');
SELECT pg_temp.try_assignment('no_read','onboarding','store_a','employee','set','42501','No manage permission');
SELECT pg_temp.try_assignment('manager','manager','store_a','employee','set','42501','No self replacement');
SELECT pg_temp.try_assignment('manager','manager','store_b',NULL,'revoke','42501','No self revocation');
SELECT pg_temp.try_assignment('org_admin','org_admin','store_a','employee','set','42501','Org admin cannot self grant');
SELECT pg_temp.try_assignment('manager','onboarding','store_b','employee','set','42501','Manager permission cannot cross to employee-only store');
SELECT pg_temp.try_assignment('manager','onboarding','store_a','location_manager','set','42501','Manager cannot grant manager');
SELECT pg_temp.try_assignment('brand_admin','onboarding','store_c','employee','set','42501','Brand admin cannot cross brands');
SELECT pg_temp.try_assignment('foreign_admin','onboarding','store_a','employee','set','42501','Foreign caller rejected');
SELECT pg_temp.try_assignment('org_admin','foreign_admin','store_a','employee','set','42501','Foreign target rejected');
SELECT pg_temp.try_assignment('org_admin','onboarding','store_a','brand_admin','set','42501','Brand role rejected');
SELECT pg_temp.try_assignment('org_admin','onboarding','store_a','org_admin','set','42501','Org role rejected');
SELECT pg_temp.try_assignment('org_admin',NULL,'store_a','employee','set','22004','Null target');
SELECT pg_temp.try_assignment('org_admin','onboarding',NULL,'employee','set','22004','Null location');
SELECT pg_temp.try_assignment('org_admin','onboarding','store_a',NULL,'set','22004','Null role');
SELECT pg_temp.try_assignment('manager','onboarding','store_a','employee','set','granted','Manager grants new employee');
SELECT pg_temp.try_assignment('manager','onboarding','store_a','employee','set','unchanged','Authorized repeated grant is no-op');
SELECT pg_temp.try_assignment('brand_admin','onboarding','store_a','location_manager','set','replaced','Brand admin promotes employee');
SELECT pg_temp.try_assignment('manager','onboarding','store_a','employee','set','42501','Manager cannot downgrade existing manager');
SELECT pg_temp.try_assignment('manager','onboarding','store_a',NULL,'revoke','42501','Manager cannot revoke existing manager');
SELECT pg_temp.try_assignment('brand_admin','onboarding','store_a',NULL,'revoke','revoked','Brand admin revokes manager');
SELECT pg_temp.try_assignment('brand_admin','onboarding','store_a',NULL,'revoke','42501','Missing assignment is rejected');
SELECT pg_temp.try_assignment('org_admin','onboarding','store_c','location_manager','set','granted','Org admin grants in another own-org brand');
SELECT pg_temp.try_assignment('org_admin','onboarding','store_c',NULL,'revoke','revoked','Org admin revokes own-org assignment');
SELECT pg_temp.try_assignment('manager','onboarding','store_a','employee','set','granted','Manager regrants employee');
SELECT pg_temp.try_assignment('manager','onboarding','store_a',NULL,'revoke','revoked','Manager revokes employee');
SELECT pg_temp.try_assignment('org_admin','inactive_target','store_a','employee','set','55000','Grant to inactive user rejected');
SELECT pg_temp.try_assignment('org_admin','inactive_target','store_a',NULL,'revoke','revoked','Inactive target assignment can be removed');
SELECT pg_temp.try_assignment('org_admin','onboarding','store_off','employee','set','55000','Inactive location grant rejected');
SELECT pg_temp.try_assignment('org_admin','off_employee','store_off',NULL,'revoke','revoked','Org admin cleans inactive location');
SELECT pg_temp.try_assignment('org_admin','onboarding','store_a','employee','set','22004','Null request ID',true);

-- A failed audit insert must roll back an otherwise valid assignment change.
CREATE FUNCTION pg_temp.reject_test_audit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'Injected audit failure' USING ERRCODE='P0001'; END $$;
CREATE TRIGGER verification_audit_failure BEFORE INSERT ON identity_access.assignment_audit_log
FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_test_audit();
SELECT pg_temp.try_assignment('manager','onboarding','store_a','employee','set','P0001','Audit failure rolls back grant');
SELECT pg_temp.try_assignment('brand_admin','employee_a','store_a','location_manager','set','P0001','Audit failure rolls back replacement');
SELECT pg_temp.try_assignment('manager','employee_a','store_a',NULL,'revoke','P0001','Audit failure rolls back revoke');
DROP TRIGGER verification_audit_failure ON identity_access.assignment_audit_log;
UPDATE public.brands SET is_active=false WHERE id=pg_temp.pid('brand_a');
SELECT pg_temp.try_assignment('org_admin','onboarding','store_a','employee','set','55000','Inactive brand rejects grant');
SELECT pg_temp.try_assignment('brand_admin','employee_a','store_a',NULL,'revoke','42501','Inactive brand removes brand-admin authority');
SELECT pg_temp.try_assignment('org_admin','employee_a','store_a',NULL,'revoke','revoked','Org admin cleans inactive brand');
UPDATE public.brands SET is_active=true WHERE id=pg_temp.pid('brand_a');
-- Ordinary runtime still cannot bypass entry points, even as an org admin.
SELECT set_config('app.user_id',pg_temp.pid('org_admin')::text,true);
SET LOCAL ROLE operations_hub_runtime;
DO $$ DECLARE stmt text; BEGIN
 FOREACH stmt IN ARRAY ARRAY[
 'INSERT INTO public.user_locations SELECT * FROM public.user_locations LIMIT 1',
 'UPDATE public.user_locations SET role_id=role_id',
 'DELETE FROM public.user_locations',
 'INSERT INTO identity_access.assignment_audit_log DEFAULT VALUES',
 'UPDATE identity_access.assignment_audit_log SET action=action',
 'DELETE FROM identity_access.assignment_audit_log',
 'SET LOCAL ROLE operations_hub_assignment_writer',
 'SELECT identity_access.can_manage_location_assignment(NULL,NULL,NULL)'] LOOP
  BEGIN
   EXECUTE stmt;
   RAISE EXCEPTION 'Unexpected success: %',stmt;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
 END LOOP;
END $$;
RESET ROLE;
SELECT pg_temp.wcheck(true,'Direct writes, role switching and private helper calls denied');
SELECT 'PASS: '||test AS result FROM write_results ORDER BY test;
SELECT count(*) AS passed_checks FROM write_results;
ROLLBACK;
