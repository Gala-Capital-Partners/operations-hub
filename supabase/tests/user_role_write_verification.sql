-- LOCAL Supabase after migrations 1-10, as postgres, one connection.
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


CREATE TEMP TABLE role_write_results(test text PRIMARY KEY);
CREATE FUNCTION pg_temp.rcheck(ok boolean,label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %',label; END IF;
 INSERT INTO pg_temp.role_write_results VALUES(label);
END $$;

-- Check configuration before granting temporary test-only role membership.
DO $$ DECLARE fn text; who text; BEGIN
 FOREACH fn IN ARRAY ARRAY['identity_access.grant_user_role(uuid,uuid,uuid,uuid)',
 'identity_access.revoke_user_role(uuid,uuid,uuid,uuid)'] LOOP
  PERFORM pg_temp.rcheck((SELECT prosecdef AND provolatile='v'
   AND proowner='operations_hub_assignment_writer'::regrole
   AND 'search_path=""'=ANY(proconfig) FROM pg_proc WHERE oid=fn::regprocedure)
   AND has_function_privilege('operations_hub_runtime',fn,'EXECUTE'),'Entry security: '||fn);
  FOREACH who IN ARRAY ARRAY['anon','authenticated'] LOOP
   PERFORM pg_temp.rcheck(NOT has_function_privilege(who,fn,'EXECUTE'),who||' denied: '||fn);
  END LOOP;
 END LOOP;
 FOREACH fn IN ARRAY ARRAY['identity_access.can_manage_user_role(uuid,uuid,uuid)',
 'identity_access.user_role_target(uuid,uuid)'] LOOP
  PERFORM pg_temp.rcheck((SELECT prosecdef AND provolatile='s'
   AND proowner='operations_hub_auth_reader'::regrole
   AND 'search_path=""'=ANY(proconfig) FROM pg_proc WHERE oid=fn::regprocedure)
   AND has_function_privilege('operations_hub_assignment_writer',fn,'EXECUTE')
   AND NOT has_function_privilege('operations_hub_runtime',fn,'EXECUTE'),'Private helper: '||fn);
 END LOOP;
 PERFORM pg_temp.rcheck(NOT pg_has_role('postgres','operations_hub_assignment_writer','SET')
  AND NOT pg_has_role('postgres','operations_hub_auth_reader','SET')
  AND NOT pg_has_role('operations_hub_runtime','operations_hub_assignment_writer','MEMBER')
  AND NOT has_schema_privilege('operations_hub_assignment_writer','identity_access','CREATE')
  AND NOT has_schema_privilege('operations_hub_auth_reader','identity_access','CREATE'),
  'Temporary ownership privileges removed');
 PERFORM pg_temp.rcheck(NOT has_any_column_privilege('operations_hub_assignment_writer','public.user_roles','UPDATE'),
  'Writer cannot update assignments in place');
END $$;
GRANT operations_hub_runtime TO postgres WITH INHERIT FALSE, SET TRUE;

-- Execute the actual entry points as runtime. Check state as postgres afterward.
-- Whole-table snapshots also catch collateral changes outside the requested row.
CREATE FUNCTION pg_temp.try_role(actor text,target text,role_key text,brand text,
 operation text,expected text,label text,missing_request boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql SECURITY INVOKER AS $$
DECLARE a uuid:=pg_temp.pid(actor); u uuid:=pg_temp.pid(target); b uuid:=pg_temp.pid(brand);
 r uuid; req uuid:=gen_random_uuid(); result text; err text;
 before_rows jsonb; after_rows jsonb; before_audit jsonb; after_audit jsonb;
 event identity_access.assignment_audit_log%ROWTYPE; n bigint;
BEGIN
 SELECT id INTO r FROM public.roles WHERE key=role_key;
 IF target='unknown' THEN u:=gen_random_uuid(); END IF;
 IF brand='unknown' THEN b:=gen_random_uuid(); END IF;
 IF role_key='unknown' THEN r:=gen_random_uuid(); END IF;
 SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') INTO before_rows FROM public.user_roles t;
 SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') INTO before_audit FROM identity_access.assignment_audit_log t;
 PERFORM set_config('app.user_id',CASE WHEN actor='malformed' THEN 'bad-uuid' ELSE COALESCE(a::text,'') END,true);
 EXECUTE 'SET LOCAL ROLE operations_hub_runtime';
 BEGIN
  IF operation='grant' THEN
   result:=identity_access.grant_user_role(u,r,b,CASE WHEN missing_request THEN NULL ELSE req END);
  ELSE
   result:=identity_access.revoke_user_role(u,r,b,CASE WHEN missing_request THEN NULL ELSE req END);
  END IF;
 EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS err=RETURNED_SQLSTATE;
 END;
 EXECUTE 'RESET ROLE';
 SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') INTO after_rows FROM public.user_roles t;
 SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') INTO after_audit FROM identity_access.assignment_audit_log t;
 IF expected IN ('granted','unchanged','revoked') THEN
  PERFORM pg_temp.rcheck(err IS NULL AND result=expected,label||': result');
  SELECT count(*) INTO n FROM public.user_roles WHERE user_id=u AND role_id=r AND brand_id IS NOT DISTINCT FROM b;
  PERFORM pg_temp.rcheck(n=CASE WHEN expected='revoked' THEN 0 ELSE 1 END,label||': assignment count');
  IF expected='unchanged' THEN
   PERFORM pg_temp.rcheck(before_rows=after_rows AND before_audit=after_audit,label||': no-op');
  ELSE
   SELECT count(*) INTO n FROM identity_access.assignment_audit_log WHERE request_id=req;
   SELECT * INTO event FROM identity_access.assignment_audit_log WHERE request_id=req;
   PERFORM pg_temp.rcheck(n=1 AND jsonb_array_length(after_audit)=jsonb_array_length(before_audit)+1
    AND event.actor_user_id=a AND event.target_user_id=u
    AND event.organization_id=(SELECT organization_id FROM public.users WHERE id=u)
    AND event.assignment_scope=CASE WHEN b IS NULL THEN 'organization' ELSE 'brand' END
    AND event.brand_id IS NOT DISTINCT FROM b AND event.location_id IS NULL
    AND event.action=operation AND event.occurred_at IS NOT NULL
    AND event.old_role_id IS NOT DISTINCT FROM CASE WHEN operation='revoke' THEN r ELSE NULL::uuid END
    AND event.new_role_id IS NOT DISTINCT FROM CASE WHEN operation='grant' THEN r ELSE NULL::uuid END,
    label||': exact audit');
   -- Only the requested assignment may change.
   PERFORM pg_temp.rcheck(
    (SELECT COALESCE(jsonb_agg(x ORDER BY x->>'id'),'[]') FROM jsonb_array_elements(before_rows) x
      WHERE NOT (x->>'user_id'=u::text AND x->>'role_id'=r::text AND (x->>'brand_id') IS NOT DISTINCT FROM b::text))
    =
    (SELECT COALESCE(jsonb_agg(x ORDER BY x->>'id'),'[]') FROM jsonb_array_elements(after_rows) x
      WHERE NOT (x->>'user_id'=u::text AND x->>'role_id'=r::text AND (x->>'brand_id') IS NOT DISTINCT FROM b::text)),
    label||': unrelated assignments preserved');
  END IF;
 ELSE
  PERFORM pg_temp.rcheck(err=expected,label||': SQLSTATE '||expected);
  PERFORM pg_temp.rcheck(before_rows=after_rows AND before_audit=after_audit,label||': no partial changes');
 END IF;
END $$;
SELECT pg_temp.try_role(NULL,'onboarding','brand_admin','brand_a','grant','42501','grant: denied actor None');
SELECT pg_temp.try_role('malformed','onboarding','brand_admin','brand_a','grant','42501','grant: denied actor malformed');
SELECT pg_temp.try_role('no_profile','onboarding','brand_admin','brand_a','grant','42501','grant: denied actor no_profile');
SELECT pg_temp.try_role('inactive_target','onboarding','brand_admin','brand_a','grant','42501','grant: denied actor inactive_target');
SELECT pg_temp.try_role('employee_a','onboarding','brand_admin','brand_a','grant','42501','grant: denied actor employee_a');
SELECT pg_temp.try_role('manager','onboarding','brand_admin','brand_a','grant','42501','grant: denied actor manager');
SELECT pg_temp.try_role('brand_admin','onboarding','brand_admin','brand_a','grant','42501','grant: denied actor brand_admin');
SELECT pg_temp.try_role('foreign_admin','onboarding','brand_admin','brand_a','grant','42501','grant: denied actor foreign_admin');
SELECT pg_temp.try_role('org_admin','org_admin','org_admin',NULL,'grant','42501','grant: self org');
SELECT pg_temp.try_role('org_admin','org_admin','brand_admin','brand_a','grant','42501','grant: self brand');
SELECT pg_temp.try_role('org_admin','foreign_admin','org_admin',NULL,'grant','42501','grant: foreign user');
SELECT pg_temp.try_role('org_admin','onboarding','brand_admin','brand_foreign','grant','42501','grant: foreign brand');
SELECT pg_temp.try_role('org_admin','onboarding','org_admin','brand_a','grant','42501','grant: org with brand');
SELECT pg_temp.try_role('org_admin','onboarding','brand_admin',NULL,'grant','42501','grant: brand missing');
SELECT pg_temp.try_role('org_admin','onboarding','employee','brand_a','grant','42501','grant: location role');
SELECT pg_temp.try_role('org_admin','unknown','org_admin',NULL,'grant','42501','grant: unknown user');
SELECT pg_temp.try_role('org_admin','onboarding','unknown',NULL,'grant','42501','grant: unknown role');
SELECT pg_temp.try_role('org_admin','onboarding','brand_admin','unknown','grant','42501','grant: unknown brand');
SELECT pg_temp.try_role('org_admin',NULL,'org_admin',NULL,'grant','22004','grant: null user');
SELECT pg_temp.try_role('org_admin','onboarding',NULL,NULL,'grant','22004','grant: null role');
SELECT pg_temp.try_role('org_admin','onboarding','org_admin',NULL,'grant','22004','grant: null request',true);
SELECT pg_temp.try_role(NULL,'onboarding','brand_admin','brand_a','revoke','42501','revoke: denied actor None');
SELECT pg_temp.try_role('malformed','onboarding','brand_admin','brand_a','revoke','42501','revoke: denied actor malformed');
SELECT pg_temp.try_role('no_profile','onboarding','brand_admin','brand_a','revoke','42501','revoke: denied actor no_profile');
SELECT pg_temp.try_role('inactive_target','onboarding','brand_admin','brand_a','revoke','42501','revoke: denied actor inactive_target');
SELECT pg_temp.try_role('employee_a','onboarding','brand_admin','brand_a','revoke','42501','revoke: denied actor employee_a');
SELECT pg_temp.try_role('manager','onboarding','brand_admin','brand_a','revoke','42501','revoke: denied actor manager');
SELECT pg_temp.try_role('brand_admin','onboarding','brand_admin','brand_a','revoke','42501','revoke: denied actor brand_admin');
SELECT pg_temp.try_role('foreign_admin','onboarding','brand_admin','brand_a','revoke','42501','revoke: denied actor foreign_admin');
SELECT pg_temp.try_role('org_admin','org_admin','org_admin',NULL,'revoke','42501','revoke: self org');
SELECT pg_temp.try_role('org_admin','org_admin','brand_admin','brand_a','revoke','42501','revoke: self brand');
SELECT pg_temp.try_role('org_admin','foreign_admin','org_admin',NULL,'revoke','42501','revoke: foreign user');
SELECT pg_temp.try_role('org_admin','onboarding','brand_admin','brand_foreign','revoke','42501','revoke: foreign brand');
SELECT pg_temp.try_role('org_admin','onboarding','org_admin','brand_a','revoke','42501','revoke: org with brand');
SELECT pg_temp.try_role('org_admin','onboarding','brand_admin',NULL,'revoke','42501','revoke: brand missing');
SELECT pg_temp.try_role('org_admin','onboarding','employee','brand_a','revoke','42501','revoke: location role');
SELECT pg_temp.try_role('org_admin','unknown','org_admin',NULL,'revoke','42501','revoke: unknown user');
SELECT pg_temp.try_role('org_admin','onboarding','unknown',NULL,'revoke','42501','revoke: unknown role');
SELECT pg_temp.try_role('org_admin','onboarding','brand_admin','unknown','revoke','42501','revoke: unknown brand');
SELECT pg_temp.try_role('org_admin',NULL,'org_admin',NULL,'revoke','22004','revoke: null user');
SELECT pg_temp.try_role('org_admin','onboarding',NULL,NULL,'revoke','22004','revoke: null role');
SELECT pg_temp.try_role('org_admin','onboarding','org_admin',NULL,'revoke','22004','revoke: null request',true);
SELECT pg_temp.try_role('org_admin','onboarding','org_admin',NULL,'grant','granted','Grant org_admin None');
SELECT pg_temp.try_role('org_admin','onboarding','org_admin',NULL,'grant','unchanged','Duplicate org_admin None');
SELECT pg_temp.try_role('org_admin','onboarding','brand_admin','brand_a','grant','granted','Grant brand_admin brand_a');
SELECT pg_temp.try_role('org_admin','onboarding','brand_admin','brand_a','grant','unchanged','Duplicate brand_admin brand_a');
SELECT pg_temp.try_role('org_admin','onboarding','brand_admin','brand_b','grant','granted','Grant brand_admin brand_b');
SELECT pg_temp.try_role('org_admin','onboarding','brand_admin','brand_b','grant','unchanged','Duplicate brand_admin brand_b');
SELECT pg_temp.try_role('brand_admin','onboarding','brand_admin','brand_a','grant','42501','Unauthorized duplicate');
SELECT pg_temp.try_role('org_admin','onboarding','org_admin',NULL,'revoke','revoked','Revoke org_admin None');
SELECT pg_temp.try_role('org_admin','onboarding','org_admin',NULL,'revoke','42501','Missing org_admin None');
SELECT pg_temp.try_role('org_admin','onboarding','brand_admin','brand_a','revoke','revoked','Revoke brand_admin brand_a');
SELECT pg_temp.try_role('org_admin','onboarding','brand_admin','brand_a','revoke','42501','Missing brand_admin brand_a');
SELECT pg_temp.try_role('org_admin','onboarding','brand_admin','brand_b','revoke','revoked','Revoke brand_admin brand_b');
SELECT pg_temp.try_role('org_admin','onboarding','brand_admin','brand_b','revoke','42501','Missing brand_admin brand_b');
SELECT pg_temp.try_role('org_admin','inactive_target','org_admin',NULL,'grant','55000','Inactive user grant');

-- Existing inactive-user and inactive-brand assignments remain removable.
INSERT INTO public.user_roles(user_id,organization_id,role_id,role_scope)
SELECT pg_temp.pid('inactive_target'),pg_temp.pid('org_a'),id,scope FROM public.roles WHERE key='org_admin';
SELECT pg_temp.try_role('org_admin','inactive_target','org_admin',NULL,'revoke','revoked','Inactive user cleanup');
UPDATE public.brands SET is_active=false WHERE id=pg_temp.pid('brand_a');
SELECT pg_temp.try_role('org_admin','onboarding','brand_admin','brand_a','grant','55000','Inactive brand grant');
SELECT pg_temp.try_role('org_admin','brand_admin','brand_admin','brand_a','revoke','revoked','Inactive brand cleanup');
UPDATE public.brands SET is_active=true WHERE id=pg_temp.pid('brand_a');

-- Inject an audit failure, then verify both kinds of grant/revoke are atomic.
SELECT pg_temp.try_role('org_admin','employee_a','org_admin',NULL,'grant','granted','Prepare org revoke');
SELECT pg_temp.try_role('org_admin','employee_a','brand_admin','brand_a','grant','granted','Prepare brand revoke');
CREATE FUNCTION pg_temp.reject_role_audit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'Injected audit failure' USING ERRCODE='P0001'; END $$;
CREATE TRIGGER verification_role_audit_failure BEFORE INSERT ON identity_access.assignment_audit_log
FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_role_audit();
SELECT pg_temp.try_role('org_admin','onboarding','org_admin',NULL,'grant','P0001','Org grant audit rollback');
SELECT pg_temp.try_role('org_admin','onboarding','brand_admin','brand_a','grant','P0001','Brand grant audit rollback');
SELECT pg_temp.try_role('org_admin','employee_a','org_admin',NULL,'revoke','P0001','Org revoke audit rollback');
SELECT pg_temp.try_role('org_admin','employee_a','brand_admin','brand_a','revoke','P0001','Brand revoke audit rollback');
DROP TRIGGER verification_role_audit_failure ON identity_access.assignment_audit_log;

-- Runtime cannot bypass the controlled entry points.
SELECT set_config('app.user_id',pg_temp.pid('org_admin')::text,true);
SET LOCAL ROLE operations_hub_runtime;
DO $$ DECLARE stmt text; BEGIN
 FOREACH stmt IN ARRAY ARRAY[
 'INSERT INTO public.user_roles DEFAULT VALUES',
 'UPDATE public.user_roles SET role_id=role_id',
 'DELETE FROM public.user_roles',
 'INSERT INTO identity_access.assignment_audit_log DEFAULT VALUES',
 'SET LOCAL ROLE operations_hub_assignment_writer',
 'SELECT identity_access.can_manage_user_role(NULL,NULL,NULL)',
 'SELECT * FROM identity_access.user_role_target(NULL,NULL)'] LOOP
  BEGIN
   EXECUTE stmt;
   RAISE EXCEPTION 'Unexpected success: %',stmt;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
 END LOOP;
END $$;
RESET ROLE;
SELECT pg_temp.rcheck(true,'Runtime direct writes and private helper calls denied');

-- Invalid audit target combinations must fail even for a privileged inserter.
DO $$ DECLARE s text; b uuid; l uuid; BEGIN
 FOR s,b,l IN SELECT * FROM (VALUES
 ('organization',pg_temp.pid('brand_a'),NULL::uuid),
 ('organization',NULL::uuid,pg_temp.pid('store_a')),
 ('brand',NULL::uuid,NULL::uuid),
 ('brand',pg_temp.pid('brand_a'),pg_temp.pid('store_a')),
 ('location',NULL::uuid,NULL::uuid),
 ('location',pg_temp.pid('brand_a'),pg_temp.pid('store_a')),
 ('unknown',NULL::uuid,NULL::uuid)) x(scope,brand,location) LOOP
  BEGIN
   INSERT INTO identity_access.assignment_audit_log(actor_user_id,organization_id,target_user_id,
    assignment_scope,brand_id,location_id,action,new_role_id,request_id)
   SELECT pg_temp.pid('org_admin'),pg_temp.pid('org_a'),pg_temp.pid('onboarding'),s,b,l,
    'grant',id,gen_random_uuid() FROM public.roles WHERE key='org_admin';
   RAISE EXCEPTION 'Invalid audit target accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
 END LOOP;
END $$;
SELECT pg_temp.rcheck(true,'Invalid audit target combinations rejected');
SELECT 'PASS: '||test AS result FROM role_write_results ORDER BY test;
SELECT count(*) AS passed_checks FROM role_write_results;
ROLLBACK;
