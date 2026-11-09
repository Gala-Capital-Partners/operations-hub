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
    blank_note text;
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

    -- Incomplete tasks cannot carry draft results or notes.
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_instances SET notes=''Draft'' WHERE id=%L',instance),'23514');
    -- Neither, value-only, notes-only, and both are all valid completions.
    UPDATE public.task_instances SET completed_at=now(),completed_by=actor WHERE id=instance;
    UPDATE public.task_instances SET recorded_value=0 WHERE id=instance;
    UPDATE public.task_instances SET recorded_value=NULL,notes='Door was open' WHERE id=instance;
    UPDATE public.task_instances SET recorded_value=42.5,notes=E'Fridge checked.\n经理已通知' WHERE id=instance;
    INSERT INTO public.task_instance_events(id,instance_id,actor_id,event_type,recorded_value,notes)
        SELECT event,id,actor,'completed',recorded_value,notes FROM public.task_instances WHERE id=instance;
    -- 2000 characters, including multibyte text, are accepted; 2001 rejected.
    UPDATE public.task_instances SET notes=repeat('温',2000) WHERE id=instance;
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_instances SET notes=repeat(''x'',2001) WHERE id=%L',instance),'23514');
    INSERT INTO public.task_instance_events(instance_id,actor_id,event_type,notes)
        VALUES(instance,actor,'completed',repeat('温',2000));
    PERFORM pg_temp.expect_task_error(format('INSERT INTO public.task_instance_events(instance_id,actor_id,event_type,notes) VALUES(%L,%L,''completed'',repeat(''x'',2001))',instance,actor),'23514');
    -- Optional means NULL, not empty or whitespace-only text. Check both storage
    -- paths with otherwise valid completion state so another check cannot mask it.
    FOREACH blank_note IN ARRAY ARRAY['', '   ', E'\t', E'\n', E' \t\r\n '] LOOP
        PERFORM pg_temp.expect_task_error(format('UPDATE public.task_instances SET notes=%L WHERE id=%L',blank_note,instance),'23514');
        PERFORM pg_temp.expect_task_error(format('INSERT INTO public.task_instance_events(instance_id,actor_id,event_type,notes) VALUES(%L,%L,''completed'',%L)',instance,actor,blank_note),'23514');
    END LOOP;
    UPDATE public.task_instances SET notes=NULL WHERE id=instance;
    INSERT INTO public.task_instance_events(instance_id,actor_id,event_type,notes)
        VALUES(instance,actor,'completed',NULL);
    -- Meaningful multiline notes retain surrounding whitespace unchanged.
    UPDATE public.task_instances SET notes=E'  Checked\n  Door closed\t' WHERE id=instance;
    INSERT INTO public.task_instance_events(instance_id,actor_id,event_type,notes)
        VALUES(instance,actor,'completed',E'  Checked\n  Door closed\t');
    IF (SELECT notes FROM public.task_instances WHERE id=instance)
        IS DISTINCT FROM E'  Checked\n  Door closed\t' THEN
        RAISE EXCEPTION 'Meaningful notes were modified';
    END IF;
    UPDATE public.task_instances SET notes='Keep in history' WHERE id=instance;
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_instances SET completed_at=NULL,completed_by=NULL,recorded_value=NULL WHERE id=%L',instance),'23514');
    UPDATE public.task_instances SET completed_at=NULL,completed_by=NULL,recorded_value=NULL,notes=NULL WHERE id=instance;
    PERFORM pg_temp.expect_task_error(format('INSERT INTO public.task_instance_events(instance_id,actor_id,event_type,notes) VALUES(%L,%L,''reopened'',''New completion note'')',instance,actor),'23514');
    INSERT INTO public.task_instance_events(instance_id,actor_id,event_type) VALUES(instance,actor,'reopened');
    UPDATE public.task_instances SET completed_at=now(),completed_by=actor WHERE id=instance;
    INSERT INTO public.task_instance_events(instance_id,actor_id,event_type) VALUES(instance,actor,'completed');
    IF NOT EXISTS (SELECT 1 FROM public.task_instance_events WHERE id=event
        AND recorded_value=42.5 AND notes=E'Fridge checked.\n经理已通知') THEN
        RAISE EXCEPTION 'Prior completion data lost';
    END IF;
END;
$$;
GRANT operations_hub_runtime TO postgres WITH INHERIT FALSE, SET TRUE;
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.expect_task_error('UPDATE public.task_instances SET notes=''Unauthorized''','42501');
SELECT pg_temp.expect_task_error('UPDATE public.task_instance_events SET notes=''Unauthorized''','42501');
RESET ROLE;
-- Structural tests only; controlled completion/audit functions remain pending.
ROLLBACK;
