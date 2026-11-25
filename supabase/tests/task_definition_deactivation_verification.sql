-- Synthetic fixtures; all data and temporary role membership roll back.
BEGIN;
GRANT operations_hub_runtime TO postgres WITH INHERIT FALSE, SET TRUE;
GRANT operations_hub_scheduler TO postgres WITH INHERIT FALSE, SET TRUE;

-- Runs one statement as `role_name` (with app.user_id = actor) and returns the
-- first column as text, or the SQLSTATE when the statement fails.
CREATE FUNCTION pg_temp.run_as(role_name text, actor uuid, command text)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    result text;
BEGIN
    PERFORM set_config('app.user_id', coalesce(actor::text, ''), true);
    EXECUTE format('SET LOCAL ROLE %I', role_name);
    BEGIN
        EXECUTE command INTO result;
    EXCEPTION WHEN OTHERS THEN
        result := SQLSTATE;
    END;
    RESET ROLE;
    RETURN result;
END;
$$;

CREATE FUNCTION pg_temp.expect(actual text, expected text, label text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION '%: expected %, got %', label, expected, actual;
    END IF;
END;
$$;

CREATE FUNCTION pg_temp.version_of(definition_id uuid)
RETURNS text LANGUAGE sql AS $$
    SELECT md5((to_jsonb(d) - 'created_at' - 'updated_at')::text)
    FROM public.task_definitions d WHERE d.id = definition_id;
$$;

DO $$
DECLARE
    org_a uuid := gen_random_uuid();
    org_b uuid := gen_random_uuid();
    brand_a uuid := gen_random_uuid();
    brand_b uuid := gen_random_uuid();
    loc_la uuid := gen_random_uuid();
    -- UTC+14 and UTC-11: their local dates always differ, so a per-store
    -- "today" is distinguishable from any single shared date.
    loc_east uuid := gen_random_uuid();
    loc_west uuid := gen_random_uuid();
    loc_b uuid := gen_random_uuid();
    employee uuid := gen_random_uuid();
    manager uuid := gen_random_uuid();
    brand_admin uuid := gen_random_uuid();
    org_admin uuid := gen_random_uuid();
    outsider uuid := gen_random_uuid();
    def_store uuid := gen_random_uuid();
    def_brand uuid := gen_random_uuid();
    def_other_brand uuid := gen_random_uuid();
    base date := (now() AT TIME ZONE 'UTC')::date;
    days text;
    deact text := 'SELECT concat_ws(''|'', is_active, deactivated_at IS NOT NULL, cancelled_instance_count) FROM public.deactivate_task_definition(%L)';
    sched text := 'SELECT public.scheduler_generate_task_instances(%L, %L::date[], %L)';
    gen text := 'SELECT public.generate_task_instances(%L, %L::date[], %L)';
    old_version text;
    first_deactivated timestamptz;
    future_done uuid;
    today_open uuid;
    future_open uuid;
    events_before integer;
    east_today date := (now() AT TIME ZONE 'Pacific/Kiritimati')::date;
    west_today date := (now() AT TIME ZONE 'Pacific/Pago_Pago')::date;
    la_today date := (now() AT TIME ZONE 'America/Los_Angeles')::date;
BEGIN
    days := format('{%s}', (SELECT string_agg(d::date::text, ',')
                            FROM generate_series(base - 3, base + 3, interval '1 day') AS d));

    INSERT INTO public.organizations(id, name) VALUES (org_a, 'Deactivation A'), (org_b, 'Deactivation B');
    INSERT INTO public.brands(id, organization_id, name, slug) VALUES
        (brand_a, org_a, 'A', brand_a::text),
        (brand_b, org_a, 'B', brand_b::text);
    INSERT INTO public.locations(id, brand_id, name, timezone, is_active) VALUES
        (loc_la, brand_a, 'Los Angeles', 'America/Los_Angeles', true),
        (loc_east, brand_a, 'Kiritimati', 'Pacific/Kiritimati', true),
        (loc_west, brand_a, 'Pago Pago', 'Pacific/Pago_Pago', true),
        (loc_b, brand_b, 'Other brand', 'UTC', true);
    INSERT INTO auth.users(id)
        SELECT unnest(ARRAY[employee, manager, brand_admin, org_admin, outsider]);
    INSERT INTO public.users(id, organization_id, email, full_name)
        SELECT id, CASE WHEN id = outsider THEN org_b ELSE org_a END,
               id::text || '@example.invalid', 'Deactivation user'
        FROM unnest(ARRAY[employee, manager, brand_admin, org_admin, outsider]) AS u(id);
    INSERT INTO public.user_locations(user_id, organization_id, brand_id, location_id, role_id)
        SELECT actor, org_a, brand_a, loc_la, r.id
        FROM (VALUES (employee, 'employee'), (manager, 'location_manager')) AS v(actor, role_key)
        JOIN public.roles AS r ON r.key = v.role_key;
    INSERT INTO public.user_roles(user_id, organization_id, brand_id, role_id, role_scope)
        SELECT actor, org, brand, r.id, r.scope
        FROM (VALUES (org_admin, org_a, NULL::uuid, 'org_admin'),
                     (brand_admin, org_a, brand_a, 'brand_admin'),
                     (outsider, org_b, NULL::uuid, 'org_admin')) AS v(actor, org, brand, role_key)
        JOIN public.roles AS r ON r.key = v.role_key;

    INSERT INTO public.task_definitions(
        id, brand_id, location_id, created_by, name, description, category,
        recurrence_rule, start_date, schedule_mode, scheduled_times
    ) VALUES
        (def_store, brand_a, loc_la, manager, 'Open registers', '', 'Opening',
         'FREQ=DAILY', base - 10, 'all_day', '{}'),
        (def_brand, brand_a, NULL, brand_admin, 'Check fridge', '', 'Midday',
         'FREQ=DAILY', base - 10, 'timed', '{10:00,18:00}'),
        (def_other_brand, brand_b, NULL, org_admin, 'Other brand task', '', 'Opening',
         'FREQ=DAILY', base - 10, 'all_day', '{}');

    -- Generate real occurrences (base-3 .. base+3 in every target store).
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_scheduler', NULL,
        format(sched, def_store, days, pg_temp.version_of(def_store))), '7', 'store generation');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_scheduler', NULL,
        format(sched, def_brand, days, pg_temp.version_of(def_brand))), '42', 'brand generation');

    -- Complete one future and leave today's open (store definition, LA).
    SELECT id INTO future_done FROM public.task_instances
    WHERE definition_id = def_store AND scheduled_day = la_today + 1;
    SELECT id INTO today_open FROM public.task_instances
    WHERE definition_id = def_store AND scheduled_day = la_today;
    SELECT id INTO future_open FROM public.task_instances
    WHERE definition_id = def_store AND scheduled_day = la_today + 2;
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', employee,
        format('SELECT completed_at IS NOT NULL FROM public.complete_task_instance(%L)', future_done)),
        'true', 'complete future occurrence before deactivation');
    SELECT count(*) INTO events_before FROM public.task_instance_events WHERE instance_id = future_done;

    -- Authorization: same rule as definition creation; nothing changes when denied.
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', NULL,
        format(deact, def_store)), '42501', 'no actor');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', employee,
        format(deact, def_store)), '42501', 'employee');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', manager,
        format(deact, def_brand)), '42501', 'manager brand-wide');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', brand_admin,
        format(deact, def_other_brand)), '42501', 'brand admin other brand');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', outsider,
        format(deact, def_store)), '42501', 'outsider');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', manager,
        format(deact, gen_random_uuid())), '42501', 'missing definition');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', manager,
        'SELECT cancelled_instance_count FROM public.deactivate_task_definition(NULL)'),
        '22004', 'null definition');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_scheduler', NULL,
        format(deact, def_store)), '42501', 'scheduler cannot deactivate');
    IF EXISTS (SELECT 1 FROM public.task_definitions WHERE id IN (def_store, def_brand, def_other_brand) AND NOT is_active)
       OR EXISTS (SELECT 1 FROM public.task_instances WHERE definition_id IN (def_store, def_brand, def_other_brand) AND cancelled_at IS NOT NULL) THEN
        RAISE EXCEPTION 'Denied deactivation changed rows';
    END IF;

    -- Runtime cannot bypass the entry point.
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', manager,
        format('UPDATE public.task_definitions SET is_active = false WHERE id = %L', def_store)),
        '42501', 'runtime direct definition update');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', manager,
        format('UPDATE public.task_instances SET cancelled_at = now(), cancelled_by = %L WHERE id = %L',
               manager, future_open)),
        '42501', 'runtime direct cancellation');

    -- Store definition: manager deactivates. Only LA days after today, uncompleted.
    old_version := pg_temp.version_of(def_store);
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', manager,
        format(deact, def_store)),
        format('f|t|%s', (base + 3) - la_today - 1), 'store deactivation');
    SELECT deactivated_at INTO first_deactivated FROM public.task_definitions WHERE id = def_store;
    PERFORM pg_temp.expect((SELECT format('%s|%s', is_active, deactivated_by = manager)
        FROM public.task_definitions WHERE id = def_store), 'f|t', 'definition audit');
    PERFORM pg_temp.expect((pg_temp.version_of(def_store) <> old_version)::text, 'true', 'version changed');

    IF EXISTS (
        SELECT 1 FROM public.task_instances i
        WHERE i.definition_id = def_store
          AND (i.cancelled_at IS NOT NULL) IS DISTINCT FROM
              (i.completed_at IS NULL AND i.scheduled_day > la_today)
    ) THEN
        RAISE EXCEPTION 'Store cancellation did not match the local-date rule';
    END IF;
    PERFORM pg_temp.expect((SELECT format('%s|%s', cancelled_at IS NULL, completed_at IS NOT NULL)
        FROM public.task_instances WHERE id = future_done), 't|t', 'completed future kept');
    PERFORM pg_temp.expect((SELECT (cancelled_at IS NULL)::text
        FROM public.task_instances WHERE id = today_open), 'true', 'today kept');
    PERFORM pg_temp.expect((SELECT (cancelled_by = manager)::text
        FROM public.task_instances WHERE id = future_open), 'true', 'cancellation audit');
    PERFORM pg_temp.expect((SELECT count(*)::text FROM public.task_instance_events WHERE instance_id = future_done),
        events_before::text, 'events untouched');
    IF EXISTS (SELECT 1 FROM public.task_instances
               WHERE definition_id IN (def_brand, def_other_brand) AND cancelled_at IS NOT NULL) THEN
        RAISE EXCEPTION 'Other definitions were cancelled';
    END IF;

    -- Repeat: success, no change.
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', org_admin,
        format(deact, def_store)), 'f|t|0', 'repeat deactivation');
    PERFORM pg_temp.expect((SELECT (deactivated_at = first_deactivated AND deactivated_by = manager)::text
        FROM public.task_definitions WHERE id = def_store), 'true', 'repeat keeps audit');
    -- Repeat still requires authorization.
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', employee,
        format(deact, def_store)), '42501', 'repeat by employee');

    -- Generation stops: stale and fresh versions insert nothing; scheduler skips it.
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_scheduler', NULL,
        format(sched, def_store, days, old_version)), '0', 'scheduler stale version');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', manager,
        format(gen, def_store, days, pg_temp.version_of(def_store))), '0', 'manager regenerate');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_scheduler', NULL,
        format('SELECT count(*) FROM public.scheduler_active_task_definitions() WHERE id = %L', def_store)),
        '0', 'scheduler skips inactive');
    PERFORM pg_temp.expect((SELECT count(*)::text FROM public.task_instances WHERE definition_id = def_store),
        '7', 'no rows recreated');

    -- Completion: cancelled occurrences are rejected; today's still works.
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', employee,
        format('SELECT id FROM public.complete_task_instance(%L)', future_open)), '55000', 'complete cancelled');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', manager,
        format('SELECT id FROM public.reopen_task_instance(%L)', future_open)), '55000', 'reopen cancelled');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', employee,
        format('SELECT completed_at IS NOT NULL FROM public.complete_task_instance(%L)', today_open)),
        'true', 'complete today after deactivation');
    -- Today's completion can be reopened. Future completed history stays completed.
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', manager,
        format('SELECT completed_at IS NULL FROM public.reopen_task_instance(%L)', today_open)),
        'true', 'reopen today');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', manager,
        format('SELECT id FROM public.reopen_task_instance(%L)', future_done)),
        '55000', 'reject reopening future completion');
    PERFORM pg_temp.expect((SELECT (completed_at IS NOT NULL AND cancelled_at IS NULL)::text
        FROM public.task_instances WHERE id = future_done), 'true', 'future completion preserved');
    PERFORM pg_temp.expect((SELECT count(*)::text FROM public.task_instance_events WHERE instance_id = future_done),
        events_before::text, 'rejected reopen leaves history untouched');

    -- Brand-wide definition: each store uses its own local today.
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', brand_admin,
        format('SELECT cancelled_instance_count > 0 FROM public.deactivate_task_definition(%L)', def_brand)),
        'true', 'brand deactivation');
    IF EXISTS (
        SELECT 1 FROM public.task_instances i
        WHERE i.definition_id = def_brand
          AND (i.cancelled_at IS NOT NULL) IS DISTINCT FROM
              (i.scheduled_day > (now() AT TIME ZONE i.timezone_snapshot)::date)
    ) THEN
        RAISE EXCEPTION 'Brand cancellation did not use each store''s local date';
    END IF;
    -- Kiritimati's today is in the future for Pago Pago: kept in one store only.
    PERFORM pg_temp.expect((SELECT string_agg(format('%s:%s', l.name, i.cancelled_at IS NOT NULL), ',' ORDER BY l.name)
        FROM public.task_instances i JOIN public.locations l ON l.id = i.location_id
        WHERE i.definition_id = def_brand AND i.scheduled_day = east_today
          AND i.location_id IN (loc_east, loc_west) AND i.scheduled_at = (
              SELECT min(j.scheduled_at) FROM public.task_instances j
              WHERE j.definition_id = def_brand AND j.location_id = i.location_id
                AND j.scheduled_day = east_today)),
        'Kiritimati:f,Pago Pago:t', 'per-store today');
    PERFORM pg_temp.expect((SELECT count(*)::text FROM public.task_instances
        WHERE definition_id = def_brand AND cancelled_at IS NULL
          AND location_id = loc_west AND scheduled_day = west_today), '2', 'west today slots kept');

    -- Other brand's definition untouched.
    PERFORM pg_temp.expect((SELECT is_active::text FROM public.task_definitions WHERE id = def_other_brand),
        'true', 'other definition active');
END;
$$;

ROLLBACK;
