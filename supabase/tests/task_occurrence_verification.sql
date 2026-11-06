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
    sibling uuid := gen_random_uuid();
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
    INSERT INTO public.task_instances(id,brand_id,location_id,definition_id,scheduled_day,name_snapshot,description_snapshot,category_snapshot,timezone_snapshot,requires_numeric_value_snapshot,scheduled_at,is_all_day_snapshot)
        VALUES(instance,brand,loc,def,'2026-11-01','Daily work','Instructions','Opening','America/Los_Angeles',false,'2026-11-01T07:00:00Z',true);

    -- Two timed occurrences for the same definition/store/local date.
    UPDATE public.task_instances SET is_all_day_snapshot=false,scheduled_at='2026-11-01T17:00:00Z' WHERE id=instance;
    INSERT INTO public.task_instances(brand_id,location_id,definition_id,scheduled_day,scheduled_at,is_all_day_snapshot,
        name_snapshot,description_snapshot,category_snapshot,timezone_snapshot,requires_numeric_value_snapshot)
    VALUES(brand,loc,def,'2026-11-01','2026-11-01T19:00:00Z',false,'Later','','Opening','America/Los_Angeles',false);
    IF (SELECT count(*) FROM public.task_instances WHERE definition_id=def AND location_id=loc) <> 2 THEN
        RAISE EXCEPTION 'Multiple daily occurrences missing';
    END IF;
    -- Different textual offsets representing the same instant must collide.
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_instances SET scheduled_at=''2026-11-01T11:00:00-08:00'' WHERE id=%L',instance),'23505');
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_instances SET scheduled_at=NULL WHERE id=%L',instance),'23502');
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_instances SET is_all_day_snapshot=NULL WHERE id=%L',instance),'23502');
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_instances SET scheduled_day=''2026-11-02'' WHERE id=%L',instance),'23514');
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_instances SET scheduled_at=''infinity'' WHERE id=%L',instance),'23514');
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_instances SET is_all_day_snapshot=true WHERE id=%L',instance),'23514');
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_instances SET timezone_snapshot=''Invalid/Zone'' WHERE id=%L',instance),'22023');

    -- Same instant at a different location is a separate occurrence.
    INSERT INTO public.locations(id,brand_id,name,timezone) VALUES(sibling,brand,'Sibling','America/Los_Angeles');
    UPDATE public.task_definitions SET location_id=NULL WHERE id=def;
    INSERT INTO public.task_instances(brand_id,location_id,definition_id,scheduled_day,scheduled_at,is_all_day_snapshot,
        name_snapshot,description_snapshot,category_snapshot,timezone_snapshot,requires_numeric_value_snapshot)
    VALUES(brand,sibling,def,'2026-11-01','2026-11-01T17:00:00Z',false,'Sibling','','Opening','America/Los_Angeles',false);

    -- Fall-back has two distinct instants with the same local wall-clock time.
    UPDATE public.task_instances SET scheduled_at='2026-11-01T08:30:00Z' WHERE id=instance;
    UPDATE public.task_instances SET scheduled_at='2026-11-01T09:30:00Z'
        WHERE definition_id=def AND location_id=loc AND id<>instance;
    IF (SELECT count(DISTINCT scheduled_at) FROM public.task_instances WHERE location_id=loc) <> 2 THEN
        RAISE EXCEPTION 'Fall-back occurrences collided';
    END IF;
    -- UTC date differs from local date; the check uses the snapshot timezone.
    UPDATE public.task_instances SET scheduled_at='2026-11-02T07:30:00Z' WHERE id=instance;
    SET LOCAL TIME ZONE 'Asia/Tokyo';
    UPDATE public.task_instances SET name_snapshot='Session zone does not change occurrence' WHERE id=instance;
    -- All-day anchor is local midnight, with the correct seasonal UTC offset.
    UPDATE public.task_instances SET scheduled_at='2026-03-08T08:00:00Z',scheduled_day='2026-03-08',is_all_day_snapshot=true WHERE id=instance;
    PERFORM pg_temp.expect_task_error(format('UPDATE public.task_instances SET scheduled_at=''2026-03-08T09:00:00Z'' WHERE id=%L',instance),'23514');
    -- Changing the offset cannot create a second all-day task on the same date.
    PERFORM pg_temp.expect_task_error(format('INSERT INTO public.task_instances(brand_id,location_id,definition_id,scheduled_day,scheduled_at,is_all_day_snapshot,name_snapshot,description_snapshot,category_snapshot,timezone_snapshot,requires_numeric_value_snapshot) VALUES(%L,%L,%L,''2026-03-08'',''2026-03-08T00:00:00Z'',true,''Duplicate all day'','''',''Opening'',''UTC'',false)',brand,loc,def),'23505');
END;
$$;
ROLLBACK;
