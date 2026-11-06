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
    invalid_rule text;
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
    INSERT INTO public.task_instances(id,brand_id,location_id,definition_id,scheduled_day,name_snapshot,description_snapshot,category_snapshot,timezone_snapshot,requires_numeric_value_snapshot)
        VALUES(instance,brand,loc,def,'2026-11-01','Daily work','Instructions','Opening','America/Los_Angeles',false);

    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_definitions SET location_id=%L WHERE id=%L',other_loc,def),'23503');
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_instances SET location_id=%L WHERE id=%L',other_loc,instance),'23503');
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_instances SET definition_id=%L WHERE id=%L',other_def,instance),'23503');
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_instances SET definition_id=NULL WHERE id=%L',instance),'23502');
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_definitions SET category=NULL WHERE id=%L',def),'23502');
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_definitions SET name=E'' \t\n'' WHERE id=%L',def),'23514');
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_definitions SET category=''Other'' WHERE id=%L',def),'23514');
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_definitions SET end_date=''2026-10-01'' WHERE id=%L',def),'23514');
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_definitions SET end_date=start_date WHERE id=%L',other_def),'23514');
    FOREACH invalid_rule IN ARRAY ARRAY['', 'FREQ=HOURLY', 'RRULE:FREQ=DAILY', E'FREQ=DAILY\nEXDATE:20261102', 'FREQ=DAILY;BYHOUR=8,9', 'FREQ=DAILY;UNTIL=20261201'] LOOP
        PERFORM pg_temp.expect_task_error(format('UPDATE public.task_definitions SET recurrence_rule=%L WHERE id=%L',invalid_rule,def),'23514');
    END LOOP;
    UPDATE public.task_definitions SET recurrence_rule='FREQ=WEEKLY;BYDAY=SU,WE,FR', end_date='2026-12-01' WHERE id=def;
    PERFORM pg_temp.expect_task_error(format('INSERT INTO public.task_instances(brand_id,location_id,definition_id,scheduled_day,name_snapshot,description_snapshot,category_snapshot,timezone_snapshot,requires_numeric_value_snapshot) VALUES(%L,%L,%L,''2026-11-01'',''Duplicate'','''',''Opening'',''America/Los_Angeles'',false)',brand,loc,def),'23505');
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_instances SET completed_at=now() WHERE id=%L',instance),'23514');
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_instances SET completed_by=%L WHERE id=%L',actor,instance),'23514');
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_instances SET completed_at=now(), completed_by=%L WHERE id=%L',gen_random_uuid(),instance),'23503');
    UPDATE public.task_instances SET completed_at=now(),completed_by=actor WHERE id=instance;
    INSERT INTO public.task_instance_events(id,instance_id,actor_id,event_type) VALUES(event,instance,actor,'completed');
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_instance_events SET event_type=''edited'' WHERE id=%L',event),'23514');
    PERFORM pg_temp.expect_task_error(format('DELETE FROM public.task_instances WHERE id=%L',instance),'23503');
    PERFORM pg_temp.expect_task_error(format('DELETE FROM public.task_definitions WHERE id=%L',def),'23503');
    PERFORM pg_temp.expect_task_error(format('DELETE FROM public.users WHERE id=%L',actor),'23503');
    UPDATE public.task_definitions SET name='New instructions',updated_at='2000-01-01' WHERE id=def;
    IF (SELECT updated_at <> now() FROM public.task_definitions WHERE id=def) THEN RAISE EXCEPTION 'Definition timestamp trigger failed'; END IF;
    IF (SELECT name_snapshot <> 'Daily work' FROM public.task_instances WHERE id=instance) THEN RAISE EXCEPTION 'Historical snapshot changed'; END IF;
    UPDATE public.task_instances SET completed_at=NULL,completed_by=NULL,updated_at='2000-01-01' WHERE id=instance;
    INSERT INTO public.task_instance_events(instance_id,actor_id,event_type) VALUES(instance,actor,'reopened');
    IF (SELECT updated_at <> now() FROM public.task_instances WHERE id=instance) THEN RAISE EXCEPTION 'Instance timestamp trigger failed'; END IF;
    IF (SELECT count(*) FROM public.task_instance_events WHERE instance_id=instance) <> 2 THEN RAISE EXCEPTION 'Event history lost'; END IF;
END;
$$;

-- Without an actor, task reads are denied. Direct writes and audit-event access are not granted.
GRANT operations_hub_runtime TO postgres WITH INHERIT FALSE, SET TRUE;
SET LOCAL ROLE operations_hub_runtime;
DO $$
BEGIN
    IF EXISTS(SELECT 1 FROM public.task_definitions) OR EXISTS(SELECT 1 FROM public.task_instances) THEN
        RAISE EXCEPTION 'Task tables must deny reads without an actor';
    END IF;
END;
$$;
SELECT pg_temp.expect_task_error('DELETE FROM public.task_definitions','42501');
SELECT pg_temp.expect_task_error('UPDATE public.task_instances SET completed_at=now()','42501');
SELECT pg_temp.expect_task_error('INSERT INTO public.task_instance_events DEFAULT VALUES','42501');
SELECT pg_temp.expect_task_error('SELECT * FROM public.task_instance_events','42501');
SELECT pg_temp.expect_task_error('DELETE FROM public.task_instance_events','42501');
SELECT pg_temp.expect_task_error('UPDATE public.task_instance_events SET event_type=''reopened''','42501');
RESET ROLE;

SELECT 'PASS: task schema constraints, history, timestamps, and default-deny access';
ROLLBACK;
