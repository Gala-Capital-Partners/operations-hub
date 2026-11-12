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
    invalid_times text;
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

    IF NOT EXISTS (SELECT 1 FROM public.task_definitions WHERE id=def
        AND schedule_mode='all_day' AND scheduled_times='{}'::time[]) THEN
        RAISE EXCEPTION 'Legacy/default definition is not all-day';
    END IF;
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_definitions SET schedule_mode=''other'' WHERE id=%L',def),'23514');
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_definitions SET schedule_mode=''timed'' WHERE id=%L',def),'23514');
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_definitions SET scheduled_times=ARRAY[TIME ''10:00''] WHERE id=%L',def),'23514');
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_definitions SET scheduled_times=NULL WHERE id=%L',def),'23502');
    -- All-day deadline remains valid; switching to timed must clear it atomically.
    UPDATE public.task_definitions SET due_time='20:00' WHERE id=def;
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_definitions SET schedule_mode=''timed'',scheduled_times=ARRAY[TIME ''10:00''] WHERE id=%L',def),'23514');
    UPDATE public.task_definitions SET schedule_mode='timed',due_time=NULL,
        scheduled_times=ARRAY[TIME '10:00',TIME '14:00',TIME '18:00'] WHERE id=def;
    IF (SELECT scheduled_times FROM public.task_definitions WHERE id=def)
       IS DISTINCT FROM ARRAY[TIME '10:00',TIME '14:00',TIME '18:00'] THEN
        RAISE EXCEPTION 'Expected three local times';
    END IF;
    FOREACH invalid_times IN ARRAY ARRAY[
        '{}', '{10:00,10:00}', '{24:00}', '{NULL}', '{10:00,NULL}',
        '{{10:00,14:00},{18:00,20:00}}', '[0:1]={10:00,14:00}'
    ] LOOP
        PERFORM pg_temp.expect_task_error(format('UPDATE public.task_definitions SET scheduled_times=%L::time[] WHERE id=%L',invalid_times,def),'23514');
    END LOOP;
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_definitions SET due_time=''19:00'' WHERE id=%L',def),'23514');
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_definitions SET schedule_mode=''all_day'' WHERE id=%L',def),'23514');
    -- No hidden ordering requirement; midnight and fractional-second times work.
    UPDATE public.task_definitions SET scheduled_times=ARRAY[TIME '23:59:59.999999',TIME '00:00'] WHERE id=def;
    -- Failed edits leave the valid schedule intact; removing the final slot fails.
    UPDATE public.task_definitions SET scheduled_times=ARRAY[TIME '10:00'] WHERE id=def;
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_definitions SET scheduled_times=array_remove(scheduled_times,TIME ''10:00'') WHERE id=%L',def),'23514');
    IF (SELECT scheduled_times FROM public.task_definitions WHERE id=def) IS DISTINCT FROM ARRAY[TIME '10:00'] THEN
        RAISE EXCEPTION 'Failed edit changed the schedule';
    END IF;
    UPDATE public.task_definitions SET schedule_mode='all_day',scheduled_times='{}',due_time='20:00' WHERE id=def;
    -- Editing a definition does not rewrite an existing instance's mode snapshot.
    IF NOT (SELECT is_all_day_snapshot FROM public.task_instances WHERE id=instance) THEN
        RAISE EXCEPTION 'Instance snapshot changed';
    END IF;
    IF public.valid_task_scheduled_times(NULL) IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'Helper must reject NULL';
    END IF;
END;
$$;
GRANT operations_hub_runtime TO postgres WITH INHERIT FALSE, SET TRUE;
SET LOCAL ROLE operations_hub_runtime;
SELECT pg_temp.expect_task_error('UPDATE public.task_definitions SET scheduled_times=ARRAY[TIME ''11:00'']','42501');
SELECT pg_temp.expect_task_error('INSERT INTO public.task_definitions DEFAULT VALUES','42501');
DO $$ BEGIN
    IF EXISTS(SELECT 1 FROM public.task_definitions) THEN
        RAISE EXCEPTION 'Definition access unexpectedly enabled';
    END IF;
END $$;
RESET ROLE;
ROLLBACK;
