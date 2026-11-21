-- Synthetic fixtures; all data and temporary role membership roll back.
BEGIN;
GRANT operations_hub_runtime TO postgres WITH INHERIT FALSE, SET TRUE;
GRANT operations_hub_scheduler TO postgres WITH INHERIT FALSE, SET TRUE;

-- Runs one statement as `role_name` (with app.user_id = actor) and returns the
-- integer result, or the SQLSTATE when the statement fails.
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

-- Read the token as the fixture administrator before switching to the caller.
CREATE FUNCTION pg_temp.generator_call(template text, definition_id uuid, days text)
RETURNS text LANGUAGE sql AS $$
    SELECT format(template, definition_id, days, coalesce((
        SELECT md5((to_jsonb(d) - 'created_at' - 'updated_at')::text)
        FROM public.task_definitions d WHERE d.id=definition_id
    ), 'missing'));
$$;

DO $$
DECLARE
    org_a uuid := gen_random_uuid();
    org_b uuid := gen_random_uuid();
    brand_a uuid := gen_random_uuid();
    brand_b uuid := gen_random_uuid();
    brand_foreign uuid := gen_random_uuid();
    loc_la uuid := gen_random_uuid();
    loc_ny uuid := gen_random_uuid();
    loc_closed uuid := gen_random_uuid();
    loc_b uuid := gen_random_uuid();
    loc_foreign uuid := gen_random_uuid();
    employee uuid := gen_random_uuid();
    manager uuid := gen_random_uuid();
    brand_admin uuid := gen_random_uuid();
    org_admin uuid := gen_random_uuid();
    outsider uuid := gen_random_uuid();
    def_store uuid := gen_random_uuid();
    def_brand uuid := gen_random_uuid();
    def_one_off uuid := gen_random_uuid();
    def_ended uuid := gen_random_uuid();
    def_inactive uuid := gen_random_uuid();
    def_dst uuid := gen_random_uuid();
    def_other_brand uuid := gen_random_uuid();
    gen text := 'SELECT public.generate_task_instances(%L, %L::date[], %L)';
    sched text := 'SELECT public.scheduler_generate_task_instances(%L, %L::date[], %L)';
    first_instance uuid;
    old_version text;
BEGIN
    INSERT INTO public.organizations(id, name) VALUES (org_a, 'Generator A'), (org_b, 'Generator B');
    INSERT INTO public.brands(id, organization_id, name, slug) VALUES
        (brand_a, org_a, 'A', brand_a::text),
        (brand_b, org_a, 'B', brand_b::text),
        (brand_foreign, org_b, 'Foreign', brand_foreign::text);
    INSERT INTO public.locations(id, brand_id, name, timezone, is_active) VALUES
        (loc_la, brand_a, 'Los Angeles', 'America/Los_Angeles', true),
        (loc_ny, brand_a, 'New York', 'America/New_York', true),
        (loc_closed, brand_a, 'Closed', 'America/Chicago', false),
        (loc_b, brand_b, 'Other brand', 'UTC', true),
        (loc_foreign, brand_foreign, 'Foreign', 'UTC', true);
    INSERT INTO auth.users(id)
        SELECT unnest(ARRAY[employee, manager, brand_admin, org_admin, outsider]);
    INSERT INTO public.users(id, organization_id, email, full_name)
        SELECT id, CASE WHEN id = outsider THEN org_b ELSE org_a END,
               id::text || '@example.invalid', 'Generator user'
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
        recurrence_rule, start_date, end_date, schedule_mode, scheduled_times,
        due_time, numeric_unit, numeric_min, numeric_max, is_active
    ) VALUES
        (def_store, brand_a, loc_la, manager, 'Open registers', 'Count drawers', 'Opening',
         'FREQ=DAILY', '2026-11-01', NULL, 'all_day', '{}', '09:00', 'USD', 0, 500, true),
        (def_brand, brand_a, NULL, brand_admin, 'Check fridge', '', 'Midday',
         'FREQ=DAILY', '2026-11-01', NULL, 'timed', '{10:00,18:00}', NULL, 'F', 30, 45, true),
        (def_one_off, brand_a, loc_la, manager, 'Deep clean', '', 'Closing',
         NULL, '2026-11-05', NULL, 'all_day', '{}', NULL, NULL, NULL, NULL, true),
        (def_ended, brand_a, loc_la, manager, 'Holiday prep', '', 'Opening',
         'FREQ=DAILY', '2026-11-01', '2026-11-03', 'all_day', '{}', NULL, NULL, NULL, NULL, true),
        (def_inactive, brand_a, loc_la, manager, 'Retired task', '', 'Opening',
         'FREQ=DAILY', '2026-11-01', NULL, 'all_day', '{}', NULL, NULL, NULL, NULL, false),
        (def_dst, brand_a, loc_la, manager, 'Night check', '', 'Closing',
         NULL, '2026-03-08', NULL, 'timed', '{02:30}', NULL, NULL, NULL, NULL, true),
        (def_other_brand, brand_b, NULL, org_admin, 'Other brand task', '', 'Opening',
         'FREQ=DAILY', '2026-11-01', NULL, 'all_day', '{}', NULL, NULL, NULL, NULL, true);

    -- Authorization: same rule as definition creation.
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', NULL,
        pg_temp.generator_call(gen, def_store, '{2026-11-01}')), '42501', 'no actor');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', employee,
        pg_temp.generator_call(gen, def_store, '{2026-11-01}')), '42501', 'employee');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', manager,
        pg_temp.generator_call(gen, def_brand, '{2026-11-01}')), '42501', 'manager brand-wide');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', brand_admin,
        pg_temp.generator_call(gen, def_other_brand, '{2026-11-01}')), '42501', 'brand admin other brand');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', outsider,
        pg_temp.generator_call(gen, def_store, '{2026-11-01}')), '42501', 'outsider');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', manager,
        pg_temp.generator_call(gen, gen_random_uuid(), '{2026-11-01}')), '42501', 'missing definition');
    IF EXISTS (SELECT 1 FROM public.task_instances) THEN
        RAISE EXCEPTION 'Denied generation inserted rows';
    END IF;

    -- Store-specific all-day generation, anchored at local midnight with snapshots.
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', manager,
        pg_temp.generator_call(gen, def_store, '{2026-11-01,2026-11-02,2026-11-02}')), '2', 'manager own store');
    IF NOT EXISTS (
        SELECT 1 FROM public.task_instances
        WHERE definition_id = def_store AND location_id = loc_la
          AND scheduled_day = '2026-11-01' AND is_all_day_snapshot
          AND scheduled_at = '2026-11-01 07:00:00+00'
          AND name_snapshot = 'Open registers' AND description_snapshot = 'Count drawers'
          AND category_snapshot = 'Opening' AND due_time_snapshot = '09:00'
          AND timezone_snapshot = 'America/Los_Angeles'
          AND numeric_unit_snapshot = 'USD' AND numeric_min_snapshot = 0
          AND numeric_max_snapshot = 500 AND completed_at IS NULL
    ) THEN
        RAISE EXCEPTION 'All-day instance or snapshots are incorrect';
    END IF;

    -- Idempotent, and existing completion state is never overwritten.
    SELECT id INTO first_instance FROM public.task_instances
    WHERE definition_id = def_store AND scheduled_day = '2026-11-01';
    UPDATE public.task_instances SET completed_at = now(), completed_by = employee,
        recorded_value = 120 WHERE id = first_instance;
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', manager,
        pg_temp.generator_call(gen, def_store, '{2026-11-01,2026-11-02}')), '0', 'rerun');
    IF NOT EXISTS (SELECT 1 FROM public.task_instances WHERE id = first_instance
                   AND completed_by = employee AND recorded_value = 120) THEN
        RAISE EXCEPTION 'Rerun changed an existing instance';
    END IF;

    -- Brand-wide timed: every active store x every time, in each store's zone.
    -- 2026-11-01 is the US fall-back day; 10:00 and 18:00 are after the change.
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', brand_admin,
        pg_temp.generator_call(gen, def_brand, '{2026-11-01}')), '4', 'brand admin brand-wide');
    IF (SELECT array_agg(scheduled_at ORDER BY scheduled_at) FROM public.task_instances
        WHERE definition_id = def_brand)
       IS DISTINCT FROM ARRAY['2026-11-01 15:00+00', '2026-11-01 18:00+00',
                              '2026-11-01 23:00+00', '2026-11-02 02:00+00']::timestamptz[] THEN
        RAISE EXCEPTION 'Timed instances use incorrect instants';
    END IF;
    IF EXISTS (SELECT 1 FROM public.task_instances
               WHERE location_id IN (loc_closed, loc_b, loc_foreign)) THEN
        RAISE EXCEPTION 'Generated at an inactive or foreign store';
    END IF;
    IF EXISTS (SELECT 1 FROM public.task_instances
               WHERE definition_id = def_brand AND (is_all_day_snapshot OR scheduled_day <> '2026-11-01')) THEN
        RAISE EXCEPTION 'Timed instances have wrong mode or local day';
    END IF;

    -- Per-timezone batches must not insert the union of windows at every store.
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', brand_admin,
        pg_temp.generator_call(
            'SELECT public.generate_task_instances(%L, %L::date[], %L, ''America/Los_Angeles'')',
            def_brand, '{2026-11-17}')), '2', 'LA-only generation');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_scheduler', NULL,
        pg_temp.generator_call(
            'SELECT public.scheduler_generate_task_instances(%L, %L::date[], %L, ''America/New_York'')',
            def_brand, '{2026-11-18}')), '2', 'NY-only generation');
    IF EXISTS (SELECT 1 FROM public.task_instances WHERE definition_id=def_brand
        AND ((location_id=loc_ny AND scheduled_day='2026-11-17')
          OR (location_id=loc_la AND scheduled_day='2026-11-18'))) THEN
        RAISE EXCEPTION 'Timezone batch crossed into another local window';
    END IF;
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', brand_admin,
        format('SELECT target_timezones::text FROM public.task_definition_generation_input(%L)', def_brand)),
        '{America/Los_Angeles,America/New_York}', 'authorized target timezones');

    -- Date eligibility: one-off only on start_date; recurring bounded by dates.
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', org_admin,
        pg_temp.generator_call(gen, def_one_off, '{2026-11-04,2026-11-05,2026-11-06}')), '1', 'one-off');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', org_admin,
        pg_temp.generator_call(gen, def_ended, '{2026-10-31,2026-11-02,2026-11-03,2026-11-04}')), '2', 'end date');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', org_admin,
        pg_temp.generator_call(gen, def_inactive, '{2026-11-02}')), '0', 'inactive definition');

    -- Nonexistent slots are skipped, not shifted into another time slot.
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', manager,
        pg_temp.generator_call(gen, def_dst, '{2026-03-08}')), '0', 'DST gap skipped');
    UPDATE public.task_definitions SET scheduled_times='{02:30,03:30}' WHERE id=def_dst;
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', manager,
        pg_temp.generator_call(gen, def_dst, '{2026-03-08}')), '1', 'adjacent DST slot');
    IF NOT EXISTS (SELECT 1 FROM public.task_instances WHERE definition_id=def_dst
        AND scheduled_at='2026-03-08 10:30+00') THEN
        RAISE EXCEPTION 'The valid 03:30 occurrence is missing';
    END IF;
    -- Fall-back generates once at the standard-time (later) instant.
    UPDATE public.task_definitions SET start_date='2026-11-01', scheduled_times='{01:30}' WHERE id=def_dst;
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', manager,
        pg_temp.generator_call(gen, def_dst, '{2026-11-01}')), '1', 'DST fold once');
    IF NOT EXISTS (SELECT 1 FROM public.task_instances WHERE definition_id=def_dst
        AND scheduled_at='2026-11-01 09:30+00') THEN
        RAISE EXCEPTION 'Fold policy is not standard-time';
    END IF;

    -- Expansion based on an old definition may not use new snapshots/rules.
    SELECT md5((to_jsonb(d) - 'created_at' - 'updated_at')::text) INTO old_version
        FROM public.task_definitions d WHERE id=def_store;
    UPDATE public.task_definitions SET name='Updated registers' WHERE id=def_store;
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', manager,
        format(gen, def_store, '{2026-11-04}', old_version)), '40001', 'stale manager version');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_scheduler', NULL,
        format(sched, def_store, '{2026-11-04}', old_version)), '40001', 'stale scheduler version');
    IF EXISTS (SELECT 1 FROM public.task_instances WHERE definition_id=def_store
               AND scheduled_day='2026-11-04') THEN
        RAISE EXCEPTION 'Stale generation inserted a row';
    END IF;
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', manager,
        format('SELECT count(*) FROM public.task_definition_generation_input(%L)',def_store)), '1', 'manager input');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', employee,
        format('SELECT count(*) FROM public.task_definition_generation_input(%L)',def_store)), '42501', 'employee input denied');

    -- Input guards.
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', manager,
        pg_temp.generator_call(gen, def_store, NULL)), '22004', 'null days');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', manager,
        pg_temp.generator_call(gen, def_store,
            ARRAY(SELECT ('2026-12-01'::date + n) FROM generate_series(0,62) n)::text)),
        '22023', 'too many days');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', manager,
        pg_temp.generator_call(gen, def_store, '{2026-11-01,2027-11-01}')), '22023', 'wide date span');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', manager,
        pg_temp.generator_call(gen, def_store, '{infinity}')), '22023', 'infinite date');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', manager,
        pg_temp.generator_call(gen, def_store, '{NULL}')), '22023', 'null date');

    -- Runtime cannot use internal or scheduler functions, or write directly.
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', org_admin,
        format('SELECT identity_access.insert_task_occurrences(%L, ''{2026-11-03}'', ''unused'')', def_store)), '42501', 'runtime helper');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', org_admin,
        pg_temp.generator_call(sched, def_store, '{2026-11-03}')), '42501', 'runtime scheduler generate');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', org_admin,
        'SELECT count(*) FROM public.scheduler_active_task_definitions()'), '42501', 'runtime scheduler list');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_runtime', org_admin,
        format('INSERT INTO public.task_instances(brand_id) VALUES (%L) RETURNING 1', brand_a)), '42501', 'runtime insert');

    -- Scheduler: lists active definitions and generates without a user.
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_scheduler', NULL,
        format('SELECT count(*) FROM public.scheduler_active_task_definitions() WHERE id IN (%L, %L)',
               def_store, def_inactive)), '1', 'scheduler list');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_scheduler', NULL,
        pg_temp.generator_call(sched, def_store, '{2026-11-03}')), '1', 'scheduler generate');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_scheduler', NULL,
        pg_temp.generator_call(sched, def_store, '{2026-11-03}')), '0', 'scheduler rerun');

    -- Scheduler has no table access and no other entry points.
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_scheduler', NULL,
        'SELECT count(*) FROM public.task_definitions'), '42501', 'scheduler table read');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_scheduler', NULL,
        'SELECT count(*) FROM public.task_instances'), '42501', 'scheduler instance read');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_scheduler', NULL,
        pg_temp.generator_call(gen, def_store, '{2026-11-04}')), '42501', 'scheduler manager path');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_scheduler', NULL,
        format('SELECT identity_access.insert_task_occurrences(%L, ''{2026-11-04}'', ''unused'')', def_store)), '42501', 'scheduler helper');
    PERFORM pg_temp.expect(pg_temp.run_as('operations_hub_scheduler', NULL,
        format('SELECT public.complete_task_instance(%L)', first_instance)), '42501', 'scheduler completion');
END;
$$;

SELECT 'PASS: task instance generator verification' AS result;
ROLLBACK;
