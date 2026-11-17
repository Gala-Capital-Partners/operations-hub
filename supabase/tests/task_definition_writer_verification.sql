-- Synthetic fixtures and temporary grants roll back; no project data persists.
BEGIN;
GRANT operations_hub_runtime TO postgres WITH INHERIT FALSE, SET TRUE;
CREATE FUNCTION pg_temp.create_definition(actor uuid, brand uuid, location uuid, allowed boolean)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE result public.task_definitions;
BEGIN
    PERFORM set_config('app.user_id',coalesce(actor::text,''),true);
    SET LOCAL ROLE operations_hub_runtime;
    BEGIN
        SELECT * INTO result FROM public.create_task_definition(
            brand,location,'Test definition','','Opening','FREQ=DAILY',
            '2026-11-16',NULL,'timed',ARRAY['10:00','18:00']::time[],NULL,'C',-30,50
        );
        IF NOT allowed THEN RAISE EXCEPTION 'Unauthorized creation succeeded'; END IF;
        IF result.created_by IS DISTINCT FROM actor OR result.id IS NULL
           OR result.scheduled_times <> ARRAY['10:00','18:00']::time[] THEN
            RAISE EXCEPTION 'Incorrect returned definition';
        END IF;
    EXCEPTION WHEN insufficient_privilege THEN
        IF allowed THEN RAISE; END IF;
    END;
    RESET ROLE;
END;
$$;
-- Run as runtime and assert rejected input leaves no partial row behind.
CREATE FUNCTION pg_temp.assert_invalid_definition(
    actor uuid, brand uuid, task_name text, task_description text, unit text
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE before_count bigint;
BEGIN
    SELECT count(*) INTO before_count FROM public.task_definitions;
    PERFORM set_config('app.user_id', actor::text, true);
    SET LOCAL ROLE operations_hub_runtime;
    BEGIN
        PERFORM public.create_task_definition(
            brand,NULL,task_name,task_description,'Opening',NULL,
            '2026-11-16',NULL,'all_day',ARRAY[]::time[],NULL,unit,NULL,NULL);
        RAISE EXCEPTION 'Invalid definition was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    RESET ROLE;
    IF (SELECT count(*) FROM public.task_definitions) <> before_count THEN
        RAISE EXCEPTION 'Invalid definition left a row behind';
    END IF;
END;
$$;

DO $$
DECLARE
    org uuid:=gen_random_uuid(); other_org uuid:=gen_random_uuid();
    brand uuid:=gen_random_uuid(); other_brand uuid:=gen_random_uuid();
    foreign_brand uuid:=gen_random_uuid();
    loc uuid:=gen_random_uuid(); sibling uuid:=gen_random_uuid();
    manager uuid:=gen_random_uuid(); employee uuid:=gen_random_uuid();
    admin uuid:=gen_random_uuid(); orgadmin uuid:=gen_random_uuid();
    inactive uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
    count_before bigint;
    boundary_row public.task_definitions;
    unassigned uuid := gen_random_uuid();
    no_profile uuid := gen_random_uuid();
BEGIN
    INSERT INTO public.organizations(id,name) VALUES(org,'Test org'),(other_org,'Other');
    INSERT INTO public.brands(id,organization_id,name,slug) VALUES
        (brand,org,'Brand',brand::text),(other_brand,org,'Other brand',other_brand::text),
        (foreign_brand,other_org,'Foreign',foreign_brand::text);
    INSERT INTO public.locations(id,brand_id,name,timezone) VALUES
        (loc,brand,'Assigned','UTC'),(sibling,brand,'Sibling','UTC');
    INSERT INTO auth.users(id) SELECT unnest(ARRAY[manager,employee,admin,orgadmin,inactive,outsider]);
    INSERT INTO public.users(id,organization_id,email,full_name,is_active)
        SELECT id,CASE WHEN id=outsider THEN other_org ELSE org END,
            id::text||'@example.invalid','Fixture',id<>inactive
        FROM unnest(ARRAY[manager,employee,admin,orgadmin,inactive,outsider]) AS u(id);
    INSERT INTO public.user_locations(user_id,organization_id,brand_id,location_id,role_id)
        SELECT actor,org,brand,loc,r.id
        FROM (VALUES(manager,'location_manager'),(employee,'employee'),(inactive,'location_manager')) AS v(actor,key)
        JOIN public.roles r ON r.key=v.key;
    INSERT INTO public.user_roles(user_id,organization_id,brand_id,role_id,role_scope)
        SELECT actor,organization,target,r.id,r.scope FROM
        (VALUES(admin,org,brand,'brand_admin'),(orgadmin,org,NULL::uuid,'org_admin'),
               (outsider,other_org,NULL::uuid,'org_admin')) AS v(actor,organization,target,key)
        JOIN public.roles r ON r.key=v.key;
    INSERT INTO auth.users(id) VALUES(unassigned),(no_profile);
    INSERT INTO public.users(id,organization_id,email,full_name)
        VALUES(unassigned,org,unassigned::text||'@example.invalid','Unassigned');
    PERFORM pg_temp.create_definition(unassigned,brand,loc,false);
    PERFORM pg_temp.create_definition(no_profile,brand,loc,false);
    PERFORM pg_temp.create_definition(manager,brand,loc,true);
    PERFORM pg_temp.create_definition(manager,brand,NULL,false);
    PERFORM pg_temp.create_definition(manager,brand,sibling,false);
    PERFORM pg_temp.create_definition(employee,brand,loc,false);
    PERFORM pg_temp.create_definition(admin,brand,NULL,true);
    PERFORM pg_temp.create_definition(admin,brand,loc,true);
    PERFORM pg_temp.create_definition(admin,other_brand,NULL,false);
    PERFORM pg_temp.create_definition(orgadmin,other_brand,NULL,true);
    PERFORM pg_temp.create_definition(orgadmin,brand,sibling,true);
    PERFORM pg_temp.create_definition(orgadmin,other_brand,loc,false);
    PERFORM pg_temp.create_definition(orgadmin,foreign_brand,NULL,false);
    PERFORM pg_temp.create_definition(outsider,brand,NULL,false);
    PERFORM pg_temp.create_definition(inactive,brand,loc,false);
    PERFORM pg_temp.create_definition(NULL,brand,loc,false);
    PERFORM pg_temp.create_definition(manager,gen_random_uuid(),NULL,false);
    UPDATE public.locations SET is_active=false WHERE id=loc;
    PERFORM pg_temp.create_definition(manager,brand,loc,false);
    UPDATE public.locations SET is_active=true WHERE id=loc;
    UPDATE public.brands SET is_active=false WHERE id=brand;
    PERFORM pg_temp.create_definition(orgadmin,brand,NULL,false);
    UPDATE public.brands SET is_active=true WHERE id=brand;
    DELETE FROM public.user_locations WHERE user_id=manager;
    PERFORM pg_temp.create_definition(manager,brand,loc,false);

    PERFORM pg_temp.assert_invalid_definition(admin,brand,repeat('x',201),'',NULL);
    PERFORM pg_temp.assert_invalid_definition(admin,brand,'Valid',repeat('x',2001),NULL);
    PERFORM pg_temp.assert_invalid_definition(admin,brand,'Valid','',repeat('x',33));
    PERFORM pg_temp.assert_invalid_definition(admin,brand,repeat('😀',201),'',NULL);
    PERFORM pg_temp.assert_invalid_definition(admin,brand,'Valid',repeat('😀',2001),NULL);
    PERFORM pg_temp.assert_invalid_definition(admin,brand,'Valid','',repeat('😀',33));
    PERFORM set_config('app.user_id',admin::text,true);
    SELECT count(*) INTO count_before FROM public.task_definitions;
    SET LOCAL ROLE operations_hub_runtime;
    BEGIN
        PERFORM identity_access.can_create_task_definition(brand,NULL);
        RAISE EXCEPTION 'Internal helper unexpectedly callable by runtime';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        INSERT INTO public.task_definitions(brand_id,created_by,name,description,category,start_date)
        VALUES(brand,admin,'Direct','','Opening','2026-11-16');
        RAISE EXCEPTION 'Direct INSERT unexpectedly permitted';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        PERFORM public.create_task_definition(
            brand,NULL,'Bad','','Opening',NULL,'2026-11-16',NULL,
            'timed',ARRAY[]::time[],NULL,NULL,NULL,NULL);
        RAISE EXCEPTION 'Invalid times unexpectedly accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE public.task_definitions SET name='Unauthorized';
        RAISE EXCEPTION 'Direct UPDATE unexpectedly permitted';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        DELETE FROM public.task_definitions;
        RAISE EXCEPTION 'Direct DELETE unexpectedly permitted';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    IF EXISTS(SELECT 1 FROM public.task_definitions) THEN
        RAISE EXCEPTION 'Runtime definition read unexpectedly enabled';
    END IF;
    RESET ROLE;
    IF (SELECT count(*) FROM public.task_definitions) <> count_before THEN
        RAISE EXCEPTION 'Rejected operations wrote data';
    END IF;
    SET LOCAL ROLE operations_hub_runtime;
    SELECT * INTO boundary_row FROM public.create_task_definition(
        brand,NULL,repeat('😀',200),repeat('😀',2000),'Opening',NULL,
        '2026-11-16',NULL,'all_day',ARRAY[]::time[],NULL,repeat('😀',32),NULL,NULL);
    IF char_length(boundary_row.name) <> 200
       OR char_length(boundary_row.description) <> 2000
       OR char_length(boundary_row.numeric_unit) <> 32
       OR boundary_row.created_by <> admin
       OR boundary_row.recurrence_rule IS NOT NULL THEN
        RAISE EXCEPTION 'Unicode boundary or one-time definition failed';
    END IF;
    RESET ROLE;
    IF has_function_privilege('anon',
        'public.create_task_definition(uuid,uuid,text,text,text,text,date,date,text,time[],time,text,numeric,numeric)', 'EXECUTE')
       OR has_function_privilege('authenticated',
        'public.create_task_definition(uuid,uuid,text,text,text,text,date,date,text,time[],time,text,numeric,numeric)', 'EXECUTE') THEN
        RAISE EXCEPTION 'Browser roles can execute the creation function';
    END IF;
    IF pg_has_role('operations_hub_runtime', 'operations_hub_definition_writer', 'MEMBER') THEN
        RAISE EXCEPTION 'Runtime can assume the writer role';
    END IF;
END;
$$;
ROLLBACK;
