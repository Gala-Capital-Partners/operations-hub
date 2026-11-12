-- Synthetic fixtures; all data and temporary role membership roll back.
BEGIN;
GRANT operations_hub_runtime TO postgres WITH INHERIT FALSE, SET TRUE;

CREATE FUNCTION pg_temp.assert_task_locations(actor uuid, expected uuid[])
RETURNS void LANGUAGE plpgsql AS $$
DECLARE actual uuid[];
BEGIN
    PERFORM set_config('app.user_id', coalesce(actor::text, ''), true);
    SET LOCAL ROLE operations_hub_runtime;
    SELECT coalesce(array_agg(location_id ORDER BY location_id), ARRAY[]::uuid[])
        INTO actual FROM public.task_instances;
    IF actual IS DISTINCT FROM ARRAY(SELECT unnest(expected) ORDER BY 1) THEN
        RAISE EXCEPTION 'Unexpected locations for actor %: %, expected %', actor, actual, expected;
    END IF;
    IF EXISTS (SELECT 1 FROM public.task_definitions) THEN
        RAISE EXCEPTION 'Definition access unexpectedly enabled';
    END IF;
    RESET ROLE;
END;
$$;

DO $$
DECLARE
    org_a uuid := gen_random_uuid(); org_b uuid := gen_random_uuid();
    brand_a uuid := gen_random_uuid(); brand_b uuid := gen_random_uuid();
    brand_foreign uuid := gen_random_uuid();
    loc_a uuid := gen_random_uuid(); sibling uuid := gen_random_uuid();
    loc_b uuid := gen_random_uuid(); foreign_loc uuid := gen_random_uuid();
    employee uuid := gen_random_uuid(); manager uuid := gen_random_uuid();
    brand_admin uuid := gen_random_uuid(); org_admin uuid := gen_random_uuid();
    outsider uuid := gen_random_uuid(); no_permission uuid := gen_random_uuid();
    no_assignment uuid := gen_random_uuid(); no_profile uuid := gen_random_uuid();
    custom_role uuid := gen_random_uuid();
    def uuid; place record;
BEGIN
    INSERT INTO public.organizations(id,name) VALUES(org_a,'Task read A'),(org_b,'Task read B');
    INSERT INTO public.brands(id,organization_id,name,slug) VALUES
        (brand_a,org_a,'A',brand_a::text),(brand_b,org_a,'B',brand_b::text),
        (brand_foreign,org_b,'Foreign',brand_foreign::text);
    INSERT INTO public.locations(id,brand_id,name,timezone) VALUES
        (loc_a,brand_a,'Assigned','UTC'),(sibling,brand_a,'Sibling','UTC'),
        (loc_b,brand_b,'Other brand','UTC'),(foreign_loc,brand_foreign,'Foreign','UTC');
    INSERT INTO auth.users(id) SELECT unnest(ARRAY[employee,manager,brand_admin,org_admin,outsider,no_permission,no_assignment,no_profile]);
    INSERT INTO public.users(id,organization_id,email,full_name)
        SELECT id, CASE WHEN id=outsider THEN org_b ELSE org_a END,
            id::text || '@example.invalid','Task reader'
        FROM unnest(ARRAY[employee,manager,brand_admin,org_admin,outsider,no_permission,no_assignment]) AS u(id);
    INSERT INTO public.roles(id,key,name,scope) VALUES(custom_role,'task_read_test_no_permission','Test only','location');
    -- Directory access alone must not imply task access.
    INSERT INTO public.role_permissions(role_id,permission_id)
        SELECT custom_role,id FROM public.permissions WHERE key='locations.read';
    INSERT INTO public.user_locations(user_id,organization_id,brand_id,location_id,role_id)
        SELECT actor,org_a,brand_a,loc_a,r.id
        FROM (VALUES(employee,'employee'),(manager,'location_manager')) v(actor,role_key)
        JOIN public.roles r ON r.key=v.role_key;
    INSERT INTO public.user_locations(user_id,organization_id,brand_id,location_id,role_id)
        VALUES(no_permission,org_a,brand_a,loc_a,custom_role);
    INSERT INTO public.user_roles(user_id,organization_id,brand_id,role_id,role_scope)
        SELECT actor,org,brand,r.id,r.scope
        FROM (VALUES (org_admin,org_a,NULL::uuid,'org_admin'),
                     (brand_admin,org_a,brand_a,'brand_admin'),
                     (outsider,org_b,NULL::uuid,'org_admin')) v(actor,org,brand,role_key)
        JOIN public.roles r ON r.key=v.role_key;
    FOR place IN SELECT * FROM (VALUES(loc_a,brand_a,employee),(sibling,brand_a,employee),
                 (loc_b,brand_b,employee),(foreign_loc,brand_foreign,outsider)) v(loc,brand,creator)
    LOOP
        INSERT INTO public.task_definitions(brand_id,location_id,created_by,name,description,category,start_date)
            VALUES(place.brand,place.loc,place.creator,'Read test','','Opening','2026-11-01') RETURNING id INTO def;
        INSERT INTO public.task_instances(brand_id,location_id,definition_id,scheduled_day,name_snapshot,description_snapshot,category_snapshot,timezone_snapshot,scheduled_at,is_all_day_snapshot)
            VALUES(place.brand,place.loc,def,'2026-11-01','Read test','','Opening','UTC','2026-11-01T00:00:00Z',true);
    END LOOP;
    PERFORM pg_temp.assert_task_locations(employee,ARRAY[loc_a]);
    PERFORM pg_temp.assert_task_locations(manager,ARRAY[loc_a]);
    PERFORM pg_temp.assert_task_locations(brand_admin,ARRAY[loc_a,sibling]);
    PERFORM pg_temp.assert_task_locations(org_admin,ARRAY[loc_a,sibling,loc_b]);
    PERFORM pg_temp.assert_task_locations(outsider,ARRAY[foreign_loc]);
    PERFORM pg_temp.assert_task_locations(employee,ARRAY[loc_a]);
    PERFORM pg_temp.assert_task_locations(NULL,ARRAY[]::uuid[]);
    PERFORM pg_temp.assert_task_locations(no_permission,ARRAY[]::uuid[]);
    PERFORM pg_temp.assert_task_locations(no_assignment,ARRAY[]::uuid[]);
    PERFORM pg_temp.assert_task_locations(no_profile,ARRAY[]::uuid[]);
    UPDATE public.users SET is_active=false WHERE id=employee;
    PERFORM pg_temp.assert_task_locations(employee,ARRAY[]::uuid[]);
    UPDATE public.users SET is_active=true WHERE id=employee;
    UPDATE public.locations SET is_active=false WHERE id=loc_a;
    PERFORM pg_temp.assert_task_locations(employee,ARRAY[]::uuid[]);
    PERFORM pg_temp.assert_task_locations(org_admin,ARRAY[sibling,loc_b]);
    UPDATE public.locations SET is_active=true WHERE id=loc_a;
    UPDATE public.brands SET is_active=false WHERE id=brand_a;
    PERFORM pg_temp.assert_task_locations(brand_admin,ARRAY[]::uuid[]);
    PERFORM pg_temp.assert_task_locations(org_admin,ARRAY[loc_b]);
    UPDATE public.brands SET is_active=true WHERE id=brand_a;
    DELETE FROM public.user_locations WHERE user_id=employee;
    PERFORM pg_temp.assert_task_locations(employee,ARRAY[]::uuid[]);
    PERFORM pg_temp.assert_task_locations(manager,ARRAY[loc_a]);
END;
$$;
ROLLBACK;
