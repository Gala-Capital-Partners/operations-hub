-- Synthetic fixtures and all mutations are rolled back.
BEGIN;

CREATE FUNCTION pg_temp.expect_task_error(statement text, expected_state text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE statement;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = expected_state THEN RETURN; END IF;
        RAISE;
    END;
    RAISE EXCEPTION 'Expected SQLSTATE % for %', expected_state, statement;
END;
$$;

DO $$
DECLARE
    org uuid := gen_random_uuid();
    brand uuid := gen_random_uuid();
    other_brand uuid := gen_random_uuid();
    loc uuid := gen_random_uuid();
    other_loc uuid := gen_random_uuid();
    actor uuid := gen_random_uuid();
    def uuid := gen_random_uuid();
    other_def uuid := gen_random_uuid();
    instance uuid := gen_random_uuid();
    event uuid := gen_random_uuid();
    special text;
BEGIN
    INSERT INTO auth.users(id) VALUES(actor);
    INSERT INTO public.organizations(id,name) VALUES(org,'Task verification');
    INSERT INTO public.users(id,organization_id,email,full_name)
        VALUES(actor,org,actor::text || '@example.com','Task verifier');
    INSERT INTO public.brands(id,organization_id,name,slug) VALUES
        (brand,org,'First','task-' || brand::text),
        (other_brand,org,'Second','task-' || other_brand::text);
    INSERT INTO public.locations(id,brand_id,name,timezone) VALUES
        (loc,brand,'First store','America/Los_Angeles'),
        (other_loc,other_brand,'Second store','America/Los_Angeles');
    INSERT INTO public.task_definitions(id,brand_id,location_id,created_by,name,description,category,recurrence_rule,start_date)
        VALUES(def,brand,loc,actor,'Daily work','Instructions','Opening','FREQ=DAILY','2026-11-01'),
              (other_def,other_brand,NULL,actor,'One-off','Instructions','Closing',NULL,'2026-11-01');
    INSERT INTO public.task_instances(id,brand_id,location_id,definition_id,scheduled_day,name_snapshot,description_snapshot,category_snapshot,timezone_snapshot,scheduled_at,is_all_day_snapshot)
        VALUES(instance,brand,loc,def,'2026-11-01','Daily work','Instructions','Opening','America/Los_Angeles','2026-11-01T07:00:00Z',true);

    -- Units/bounds are optional configuration, independent of completion input.
    UPDATE public.task_definitions SET numeric_unit='USD',numeric_min=0,numeric_max=1000 WHERE id=def;
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_definitions SET numeric_unit=''  '' WHERE id=%L',def),'23514');
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_definitions SET numeric_min=1001 WHERE id=%L',def),'23514');
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_instances SET recorded_value=1 WHERE id=%L',instance),'23514');
    UPDATE public.task_instances SET numeric_unit_snapshot='USD',numeric_min_snapshot=0,numeric_max_snapshot=1000 WHERE id=instance;
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_instances SET numeric_unit_snapshot=''  '' WHERE id=%L',instance),'23514');
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_instances SET numeric_min_snapshot=1001 WHERE id=%L',instance),'23514');
    -- Completion succeeds without a reading, even when bounds are configured.
    UPDATE public.task_instances SET completed_at=now(),completed_by=actor WHERE id=instance;
    FOREACH special IN ARRAY ARRAY['NaN','Infinity','-Infinity','-0.01','1000.01'] LOOP
        PERFORM pg_temp.expect_task_error(format('UPDATE public.task_instances SET completed_at=now(),completed_by=%L,recorded_value=%L WHERE id=%L',actor,special,instance),'23514');
    END LOOP;
    FOREACH special IN ARRAY ARRAY['NaN','Infinity','-Infinity'] LOOP
        PERFORM pg_temp.expect_task_error(format('UPDATE public.task_definitions SET numeric_min=%L WHERE id=%L',special,def),'23514');
        PERFORM pg_temp.expect_task_error(format('UPDATE public.task_definitions SET numeric_max=%L WHERE id=%L',special,def),'23514');
        PERFORM pg_temp.expect_task_error(format('UPDATE public.task_instances SET numeric_min_snapshot=%L WHERE id=%L',special,instance),'23514');
        PERFORM pg_temp.expect_task_error(format('UPDATE public.task_instances SET numeric_max_snapshot=%L WHERE id=%L',special,instance),'23514');
        PERFORM pg_temp.expect_task_error(format('INSERT INTO public.task_instance_events(instance_id,actor_id,event_type,recorded_value) VALUES(%L,%L,''completed'',%L)',instance,actor,special),'23514');
    END LOOP;
    -- Inclusive bounds, zero and decimal readings are supported.
    UPDATE public.task_instances SET completed_at=now(),completed_by=actor,recorded_value=0 WHERE id=instance;
    UPDATE public.task_instances SET recorded_value=1000 WHERE id=instance;
    UPDATE public.task_instances SET recorded_value=123.45 WHERE id=instance;
    INSERT INTO public.task_instance_events(id,instance_id,actor_id,event_type,recorded_value)
        VALUES(event,instance,actor,'completed',123.45);
    UPDATE public.task_definitions SET numeric_unit='EUR',numeric_min=500,numeric_max=2000 WHERE id=def;
    IF NOT EXISTS (SELECT 1 FROM public.task_instances WHERE id=instance AND numeric_unit_snapshot='USD'
        AND numeric_min_snapshot=0 AND numeric_max_snapshot=1000 AND recorded_value=123.45) THEN
        RAISE EXCEPTION 'Definition edits changed historical meaning';
    END IF;
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_instances SET completed_at=NULL,completed_by=NULL WHERE id=%L',instance),'23514');
    UPDATE public.task_instances SET completed_at=NULL,completed_by=NULL,recorded_value=NULL WHERE id=instance;
    PERFORM pg_temp.expect_task_error(format('INSERT INTO public.task_instance_events(instance_id,actor_id,event_type,recorded_value) VALUES(%L,%L,''reopened'',123.45)',instance,actor),'23514');
    INSERT INTO public.task_instance_events(instance_id,actor_id,event_type) VALUES(instance,actor,'reopened');
    UPDATE public.task_instances SET completed_at=now(),completed_by=actor,recorded_value=456.78 WHERE id=instance;
    INSERT INTO public.task_instance_events(instance_id,actor_id,event_type,recorded_value) VALUES(instance,actor,'completed',456.78);
    IF (SELECT recorded_value FROM public.task_instance_events WHERE id=event) <> 123.45
       OR (SELECT count(*) FROM public.task_instance_events WHERE instance_id=instance) <> 3 THEN
        RAISE EXCEPTION 'Earlier reading lost after reopening/recompletion';
    END IF;
    -- Units and bounds are optional; negative decimals can be legitimate readings.
    UPDATE public.task_instances SET numeric_unit_snapshot=NULL,numeric_min_snapshot=NULL,numeric_max_snapshot=NULL,
        recorded_value=-12.345 WHERE id=instance;
    UPDATE public.task_definitions SET numeric_unit=NULL,numeric_min=NULL,numeric_max=NULL WHERE id=def;
END;
$$;
-- Structural verification only: controlled completion/audit writers are not implemented.
ROLLBACK;
