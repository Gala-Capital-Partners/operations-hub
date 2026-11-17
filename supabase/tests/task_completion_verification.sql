-- Synthetic fixtures; all data and temporary role membership roll back.
BEGIN;
GRANT operations_hub_runtime TO postgres WITH INHERIT FALSE, SET TRUE;

CREATE FUNCTION pg_temp.call_task(actor uuid, command text, expected text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    caught text;
BEGIN
    PERFORM set_config('app.user_id', coalesce(actor::text,''), true);
    SET LOCAL ROLE operations_hub_runtime;
    BEGIN
        EXECUTE command;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS caught  =  RETURNED_SQLSTATE;
    END;
    RESET ROLE;
    IF caught IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'Expected %, got % for %', expected, caught, command;
    END IF;
END;
$$;

DO $$
DECLARE
    org_a uuid := gen_random_uuid();
    org_b uuid := gen_random_uuid();
    brand_a uuid := gen_random_uuid();
    brand_b uuid := gen_random_uuid();
    brand_foreign uuid := gen_random_uuid();
    loc_a uuid := gen_random_uuid();
    sibling uuid := gen_random_uuid();
    loc_b uuid := gen_random_uuid();
    foreign_loc uuid := gen_random_uuid();
    employee uuid := gen_random_uuid();
    manager uuid := gen_random_uuid();
    brand_admin uuid := gen_random_uuid();
    org_admin uuid := gen_random_uuid();
    outsider uuid := gen_random_uuid();
    no_permission uuid := gen_random_uuid();
    no_assignment uuid := gen_random_uuid();
    no_profile uuid := gen_random_uuid();
    custom_role uuid := gen_random_uuid();
    def uuid;
    place record;
    instance uuid;
    before_row jsonb;
    bad text;
BEGIN
    INSERT INTO public.organizations(id, name) VALUES(org_a,'Task read A'), (org_b,'Task read B');
    INSERT INTO public.brands(id, organization_id, name, slug) VALUES
        (brand_a, org_a,'A', brand_a::text), (brand_b, org_a,'B', brand_b::text),
        (brand_foreign, org_b,'Foreign', brand_foreign::text);
    INSERT INTO public.locations(id, brand_id, name, timezone) VALUES
        (loc_a, brand_a,'Assigned','UTC'), (sibling, brand_a,'Sibling','UTC'),
        (loc_b, brand_b,'Other brand','UTC'), (foreign_loc, brand_foreign,'Foreign','UTC');
    INSERT INTO auth.users(id) SELECT unnest(ARRAY[employee, manager, brand_admin, org_admin, outsider,
        no_permission, no_assignment, no_profile]);
    INSERT INTO public.users(id, organization_id, email, full_name)
        SELECT id, CASE WHEN id = outsider THEN org_b ELSE org_a END,
            id::text || '@example.invalid','Task reader'
        FROM unnest(ARRAY[employee, manager, brand_admin, org_admin, outsider, no_permission,
            no_assignment]) AS u(id);
    INSERT INTO public.roles(id, key, name, scope) VALUES(custom_role,'task_read_test_no_permission',
        'Test only','location');
    -- Directory access alone must not imply task access.
    INSERT INTO public.role_permissions(role_id, permission_id)
        SELECT custom_role, id FROM public.permissions WHERE key = 'locations.read';
    INSERT INTO public.user_locations(user_id, organization_id, brand_id, location_id, role_id)
        SELECT actor, org_a, brand_a, loc_a, r.id
        FROM (VALUES(employee,'employee'), (manager,'location_manager')) v(actor, role_key)
        JOIN public.roles r ON r.key = v.role_key;
    INSERT INTO public.user_locations(user_id, organization_id, brand_id, location_id, role_id)
        VALUES(no_permission, org_a, brand_a, loc_a, custom_role);
    INSERT INTO public.user_roles(user_id, organization_id, brand_id, role_id, role_scope)
        SELECT actor, org, brand, r.id, r.scope
        FROM (VALUES (org_admin, org_a, NULL::uuid,'org_admin'),
                     (brand_admin, org_a, brand_a,'brand_admin'),
                     (outsider, org_b, NULL::uuid,'org_admin')) v(actor, org, brand, role_key)
        JOIN public.roles r ON r.key = v.role_key;
    FOR place IN SELECT * FROM (VALUES(loc_a, brand_a, employee), (sibling, brand_a, employee),
                 (loc_b, brand_b, employee), (foreign_loc, brand_foreign, outsider)) v(loc, brand, creator)
    LOOP
        INSERT INTO public.task_definitions(brand_id, location_id, created_by, name, description,
            category, start_date)
            VALUES(place.brand, place.loc, place.creator,'Read test','','Opening','2026-11-01')
                RETURNING id INTO def;
        INSERT INTO public.task_instances(brand_id, location_id, definition_id, scheduled_day,
            name_snapshot, description_snapshot, category_snapshot, timezone_snapshot, scheduled_at,
            is_all_day_snapshot)
            VALUES(place.brand, place.loc, def,'2026-11-01','Read test','','Opening','UTC',
                '2026-11-01T00:00:00Z', true);
    END LOOP;
    SELECT id INTO instance FROM public.task_instances WHERE location_id = loc_a;
    UPDATE public.task_instances SET numeric_min_snapshot = 0, numeric_max_snapshot = 100 WHERE
        id = instance;
    SELECT to_jsonb(i) INTO before_row FROM public.task_instances i WHERE id = instance;
    PERFORM pg_temp.call_task(
        NULL, format('SELECT public.complete_task_instance(%L)', instance),'42501'
    );
    PERFORM pg_temp.call_task(
        no_profile, format('SELECT public.complete_task_instance(%L)', instance),'42501'
    );
    PERFORM pg_temp.call_task(
        no_assignment, format('SELECT public.complete_task_instance(%L)', instance),'42501'
    );
    PERFORM pg_temp.call_task(
        no_permission, format('SELECT public.complete_task_instance(%L)', instance),'42501'
    );
    PERFORM pg_temp.call_task(
        outsider, format('SELECT public.complete_task_instance(%L)', instance),'42501'
    );
    PERFORM pg_temp.call_task(
        org_admin, format('SELECT public.complete_task_instance(%L)', instance),'42501'
    );
    PERFORM pg_temp.call_task(
        brand_admin, format('SELECT public.complete_task_instance(%L)', instance),'42501'
    );
    PERFORM pg_temp.call_task(
        employee, format('SELECT public.complete_task_instance(%L)', gen_random_uuid()),'42501'
    );
    -- Explicit foreign target IDs, not an RLS-filtered empty SELECT.
    PERFORM pg_temp.call_task(
        employee, format('SELECT public.complete_task_instance(%L)', (SELECT id FROM
            public.task_instances WHERE location_id = sibling)),'42501'
    );
    PERFORM pg_temp.call_task(
        employee,'SELECT public.complete_task_instance(NULL)','22004'
    );
    FOREACH bad IN ARRAY ARRAY['NaN','Infinity','-Infinity','-1','101'] LOOP
        PERFORM pg_temp.call_task(
            employee, format('SELECT public.complete_task_instance(%L,%L)', instance, bad),'22023'
        );
    END LOOP;
    PERFORM pg_temp.call_task(
        employee, format('SELECT public.complete_task_instance(%L,NULL,repeat(''x'',2001))',
            instance),'22023'
    );
    IF (SELECT to_jsonb(i) FROM public.task_instances i WHERE id = instance) IS DISTINCT FROM
        before_row
        OR EXISTS(SELECT 1 FROM public.task_instance_events) THEN
        RAISE EXCEPTION 'Denied/invalid operations changed data';
    END IF;
    PERFORM pg_temp.call_task(
        manager, format('SELECT public.reopen_task_instance(%L)', instance),'55000'
    );
    PERFORM pg_temp.call_task(
        employee, format('SELECT public.complete_task_instance(%L,42.5,%L)', instance,
            E'  Checked\nOK')
    );
    IF NOT EXISTS(SELECT 1 FROM public.task_instances i JOIN public.task_instance_events e ON
        e.instance_id = i.id
        WHERE i.id = instance AND i.completed_by = employee AND i.recorded_value = 42.5
          AND i.notes = E'  Checked\nOK' AND e.actor_id = employee AND e.recorded_value = i.recorded_value
          AND e.notes = i.notes AND e.occurred_at = i.completed_at) THEN
        RAISE EXCEPTION 'Completion and audit disagree';
    END IF;
    PERFORM pg_temp.call_task(
        employee, format('SELECT public.complete_task_instance(%L,50)', instance),'55000'
    );
    PERFORM pg_temp.call_task(
        employee, format('SELECT public.reopen_task_instance(%L)', instance),'42501'
    );
    PERFORM pg_temp.call_task(
        manager, format('SELECT public.reopen_task_instance(%L)', instance)
    );
    IF NOT EXISTS(SELECT 1 FROM public.task_instances WHERE id = instance AND completed_at IS NULL
        AND completed_by IS NULL AND recorded_value IS NULL AND notes IS NULL)
        OR (SELECT count(*) FROM public.task_instance_events WHERE instance_id = instance) <> 2 THEN
        RAISE EXCEPTION 'Reopen failed to clear state or preserve history';
    END IF;
    -- Both inputs optional; blank notes normalize to NULL.
    PERFORM pg_temp.call_task(
        employee, format('SELECT public.complete_task_instance(%L,NULL,%L)', instance, E' \t\n')
    );
    IF (SELECT notes IS NOT NULL OR recorded_value IS NOT NULL FROM public.task_instances WHERE
        id = instance) THEN
        RAISE EXCEPTION 'Optional inputs not normalized';
    END IF;
    PERFORM pg_temp.call_task(
        manager, format('SELECT public.reopen_task_instance(%L)', instance)
    );
    PERFORM pg_temp.call_task(
        employee, format('SELECT public.complete_task_instance(%L,NULL,repeat(''温'',2000))', instance)
    );
    PERFORM pg_temp.call_task(
        manager, format('SELECT public.reopen_task_instance(%L)', instance)
    );
    UPDATE public.users SET is_active = false WHERE id = employee;
    PERFORM pg_temp.call_task(
        employee, format('SELECT public.complete_task_instance(%L)', instance),'42501'
    );
    UPDATE public.users SET is_active = true WHERE id = employee;
    UPDATE public.locations SET is_active = false WHERE id = loc_a;
    PERFORM pg_temp.call_task(
        employee, format('SELECT public.complete_task_instance(%L)', instance),'42501'
    );
    UPDATE public.locations SET is_active = true WHERE id = loc_a;
    UPDATE public.brands SET is_active = false WHERE id = brand_a;
    PERFORM pg_temp.call_task(
        employee, format('SELECT public.complete_task_instance(%L)', instance),'42501'
    );
    UPDATE public.brands SET is_active = true WHERE id = brand_a;
    -- Neither internal helper nor direct table writes are available to runtime.
    PERFORM pg_temp.call_task(
        employee, format('SELECT identity_access.change_task_completion(%L,true,NULL,NULL)',
            instance),'42501'
    );
    PERFORM pg_temp.call_task(
        employee,'UPDATE public.task_instances SET notes=''bypass''','42501'
    );
    PERFORM pg_temp.call_task(
        employee,'INSERT INTO public.task_instance_events DEFAULT VALUES','42501'
    );
    PERFORM pg_temp.call_task(
        employee,'DELETE FROM public.task_instance_events','42501'
    );
    -- Only completion columns may change; snapshots and occurrence identity remain.
    IF (SELECT to_jsonb(i)-ARRAY['completed_at','completed_by','recorded_value','notes',
        'updated_at']
        FROM public.task_instances i WHERE id = instance)
       IS DISTINCT FROM before_row-ARRAY['completed_at','completed_by','recorded_value','notes',
           'updated_at'] THEN
        RAISE EXCEPTION 'Completion modified immutable task data';
    END IF;
END;
$$;
-- Deliberate event failure proves the preceding state UPDATE rolls back too.
CREATE FUNCTION pg_temp.reject_task_event() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'Injected audit failure' USING ERRCODE = '23514'; END;
$$;
CREATE TRIGGER test_reject_task_event BEFORE INSERT ON public.task_instance_events
FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_task_event();
DO $$
DECLARE i uuid;
    a uuid;
    original jsonb;
    events bigint;
BEGIN
    -- Select a location-role actor and its assigned instance deterministically.
    SELECT t.id, ul.user_id INTO i, a FROM public.task_instances t JOIN public.user_locations ul ON
        ul.location_id = t.location_id
        JOIN public.roles r ON r.id = ul.role_id WHERE r.key = 'employee' LIMIT 1;
    SELECT to_jsonb(t) INTO original FROM public.task_instances t WHERE id = i;
    SELECT count(*) INTO events FROM public.task_instance_events;
    PERFORM pg_temp.call_task(
        a, format('SELECT public.complete_task_instance(%L)', i),'23514'
    );
    IF (SELECT to_jsonb(t) FROM public.task_instances t WHERE id = i) IS DISTINCT FROM original
       OR (SELECT count(*) FROM public.task_instance_events) <> events THEN
        RAISE EXCEPTION 'Audit failure did not roll back state';
    END IF;
END;
$$;
ROLLBACK;
