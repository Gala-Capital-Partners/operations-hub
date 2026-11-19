-- Task-instance generation.
--
-- The backend decides WHICH local dates a definition's RRULE selects. This
-- migration turns (definition, dates) into rows: it chooses target stores and
-- time slots, converts local times to instants in each store's timezone, copies
-- snapshots, and inserts idempotently. Callers never supply
-- store IDs, times or snapshot values. The optional timezone only narrows
-- authoritative targets for a per-timezone rolling window.
--
-- Entry points:
--   public.generate_task_instances(definition, days, version, timezone = NULL)         runtime; manager path
--   public.scheduler_active_task_definitions()                scheduler only
--   public.scheduler_generate_task_instances(definition, days, version, timezone = NULL) scheduler only

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles
                   WHERE rolname = 'operations_hub_instance_writer') THEN
        CREATE ROLE operations_hub_instance_writer NOLOGIN;
    END IF;
    -- Privilege role for the nightly job. The LOGIN that assumes it is
    -- provisioned separately by supabase/setup/create_scheduler_login.sql.
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles
                   WHERE rolname = 'operations_hub_scheduler') THEN
        CREATE ROLE operations_hub_scheduler NOLOGIN;
    END IF;
END;
$$;
ALTER ROLE operations_hub_instance_writer
    NOLOGIN NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
ALTER ROLE operations_hub_scheduler
    NOLOGIN NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;

GRANT USAGE ON SCHEMA public, identity_access TO operations_hub_instance_writer;
GRANT USAGE ON SCHEMA public TO operations_hub_scheduler;

-- The writer reads definitions and their targets, and inserts instances only.
GRANT SELECT ON public.task_definitions, public.brands, public.locations
TO operations_hub_instance_writer;
GRANT INSERT (
    brand_id, location_id, definition_id, scheduled_day, scheduled_at,
    is_all_day_snapshot, name_snapshot, description_snapshot, category_snapshot,
    due_time_snapshot, timezone_snapshot, numeric_unit_snapshot,
    numeric_min_snapshot, numeric_max_snapshot
) ON public.task_instances TO operations_hub_instance_writer;

-- Writer-only policies. Authorization happens in the entry points below.
CREATE POLICY task_definitions_instance_writer_select ON public.task_definitions
FOR SELECT TO operations_hub_instance_writer USING (true);
CREATE POLICY brands_instance_writer_select ON public.brands
FOR SELECT TO operations_hub_instance_writer USING (true);
CREATE POLICY locations_instance_writer_select ON public.locations
FOR SELECT TO operations_hub_instance_writer USING (true);
CREATE POLICY task_instances_instance_writer_insert ON public.task_instances
FOR INSERT TO operations_hub_instance_writer WITH CHECK (true);

-- The manager path reuses the definition-creation authorization and lock.
GRANT operations_hub_auth_reader TO postgres WITH INHERIT FALSE, SET TRUE;
SET ROLE operations_hub_auth_reader;
GRANT EXECUTE ON FUNCTION
    identity_access.can_create_task_definition(uuid, uuid),
    identity_access.current_user_organization_id()
TO operations_hub_instance_writer;
RESET ROLE;
REVOKE operations_hub_auth_reader FROM postgres;
GRANT EXECUTE ON FUNCTION identity_access.lock_assignment_organization()
TO operations_hub_instance_writer;

-- Internal helper: not callable by runtime or the scheduler directly.
CREATE FUNCTION identity_access.insert_task_occurrences(
    p_definition_id uuid,
    p_days date[],
    p_expected_version text,
    p_timezone text DEFAULT NULL
) RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = ''
AS $$
DECLARE
    def public.task_definitions;
    last_day date;
    inserted integer;
BEGIN
    IF p_definition_id IS NULL OR p_days IS NULL OR p_expected_version IS NULL THEN
        RAISE EXCEPTION 'Definition, days and version are required' USING ERRCODE = '22004';
    END IF;
    -- Generation windows are short; a large array indicates a caller bug.
    IF cardinality(p_days) > 62 THEN
        RAISE EXCEPTION 'At most 62 days can be generated per call'
            USING ERRCODE = '22023';
    END IF;

    IF EXISTS (SELECT 1 FROM unnest(p_days) AS requested(day)
               WHERE day IS NULL OR NOT isfinite(day)
                  OR day < DATE '2000-01-01' OR day > DATE '2199-12-31')
       OR (SELECT max(day) - min(day) FROM unnest(p_days) AS requested(day)) > 61 THEN
        RAISE EXCEPTION 'Days must be finite, within 2000-2199, and span at most 62 days'
            USING ERRCODE = '22023';
    END IF;

    SELECT d.* INTO def
    FROM public.task_definitions AS d
    JOIN public.brands AS b ON b.id = d.brand_id
    WHERE d.id = p_definition_id AND d.is_active AND b.is_active;
    IF NOT FOUND THEN
        RETURN 0; -- Inactive definitions and brands generate nothing.
    END IF;

    -- Hash content, not JS Date precision. Exclude timestamptz serialization so
    -- the token is stable across sessions with different TimeZone settings.
    IF md5((to_jsonb(def) - 'created_at' - 'updated_at')::text)
       IS DISTINCT FROM p_expected_version THEN
        RAISE EXCEPTION 'Definition changed; reload it and recalculate occurrences'
            USING ERRCODE = '40001';
    END IF;

    -- One-off: only start_date. Recurring: start_date..end_date (open-ended
    -- when NULL). Which recurring dates match the RRULE is the caller's job.
    last_day := CASE
        WHEN def.recurrence_rule IS NULL THEN def.start_date
        ELSE coalesce(def.end_date, 'infinity'::date)
    END;

    WITH days AS (
        SELECT DISTINCT day
        FROM unnest(p_days) AS requested(day)
        WHERE day IS NOT NULL AND day >= def.start_date AND day <= last_day
    ),
    stores AS (
        -- Store-specific definitions target exactly their store; brand-wide
        -- definitions target every active store in the brand.
        SELECT l.id, l.timezone
        FROM public.locations AS l
        WHERE l.brand_id = def.brand_id AND l.is_active
          AND (def.location_id IS NULL OR l.id = def.location_id)
          AND (p_timezone IS NULL OR l.timezone = p_timezone)
    ),
    slots AS (
        SELECT NULL::time AS local_time WHERE def.schedule_mode = 'all_day'
        UNION ALL
        SELECT t FROM unnest(def.scheduled_times) AS times(t)
        WHERE def.schedule_mode = 'timed'
    )
    INSERT INTO public.task_instances (
        brand_id, location_id, definition_id, scheduled_day, scheduled_at,
        is_all_day_snapshot, name_snapshot, description_snapshot, category_snapshot,
        due_time_snapshot, timezone_snapshot, numeric_unit_snapshot,
        numeric_min_snapshot, numeric_max_snapshot
    )
    SELECT
        def.brand_id, s.id, def.id, d.day,
        resolved.instant,
        sl.local_time IS NULL,
        def.name, def.description, def.category, def.due_time, s.timezone,
        def.numeric_unit, def.numeric_min, def.numeric_max
    FROM days AS d
    CROSS JOIN stores AS s
    CROSS JOIN slots AS sl
    CROSS JOIN LATERAL (
        SELECT CASE WHEN sl.local_time IS NULL THEN d.day::timestamp
                    ELSE d.day + sl.local_time END AS wall_time
    ) AS local
    CROSS JOIN LATERAL (
        SELECT local.wall_time AT TIME ZONE s.timezone AS instant
    ) AS resolved
    -- Timed DST gaps: skip rather than shifting into another configured slot.
    -- Folds: use PostgreSQL's standard-time interpretation (one occurrence).
    -- All-day anchors follow the existing DB convention; skip wholly missing days.
    WHERE (resolved.instant AT TIME ZONE s.timezone)::date = d.day
      AND (sl.local_time IS NULL
           OR resolved.instant AT TIME ZONE s.timezone = local.wall_time)
    -- Idempotent: existing occurrences (either unique key) are left untouched.
    ON CONFLICT DO NOTHING;

    GET DIAGNOSTICS inserted = ROW_COUNT;
    RETURN inserted;
END;
$$;

-- Manager path: called in the same transaction that created the definition,
-- or later by anyone who could have created it.
CREATE FUNCTION public.generate_task_instances(
    p_definition_id uuid,
    p_days date[],
    p_expected_version text,
    p_timezone text DEFAULT NULL
) RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    target_brand uuid;
    target_location uuid;
    target_version text;
BEGIN
    -- Same lock as identity writers (reentrant within one transaction);
    -- requires READ COMMITTED and an active caller.
    PERFORM identity_access.lock_assignment_organization();

    SELECT d.brand_id, d.location_id, md5((to_jsonb(d) - 'created_at' - 'updated_at')::text)
    INTO target_brand, target_location, target_version
    FROM public.task_definitions AS d
    WHERE d.id = p_definition_id;

    -- Missing and unauthorized definitions share one error.
    IF NOT FOUND OR NOT identity_access.can_create_task_definition(
        target_brand, target_location
    ) THEN
        RAISE EXCEPTION 'Task generation is not authorized'
            USING ERRCODE = '42501';
    END IF;

    IF target_version IS DISTINCT FROM p_expected_version THEN
        RAISE EXCEPTION 'Definition changed; reload it and recalculate occurrences'
            USING ERRCODE = '40001';
    END IF;
    RETURN identity_access.insert_task_occurrences(p_definition_id, p_days, p_expected_version, p_timezone);
END;
$$;

-- Narrow manager input reader, not general-purpose definition access.
CREATE FUNCTION public.task_definition_generation_input(p_definition_id uuid)
RETURNS TABLE (
    id uuid, recurrence_rule text, start_date date, end_date date,
    definition_version text, target_timezones text[]
)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    def public.task_definitions;
BEGIN
    PERFORM identity_access.lock_assignment_organization();
    SELECT d.* INTO def FROM public.task_definitions AS d WHERE d.id = p_definition_id;
    IF NOT FOUND OR NOT identity_access.can_create_task_definition(def.brand_id, def.location_id) THEN
        RAISE EXCEPTION 'Task generation is not authorized' USING ERRCODE = '42501';
    END IF;
    RETURN QUERY SELECT def.id, def.recurrence_rule, def.start_date, def.end_date,
        md5((to_jsonb(def) - 'created_at' - 'updated_at')::text),
        ARRAY(SELECT DISTINCT l.timezone FROM public.locations AS l
              WHERE l.brand_id = def.brand_id AND l.is_active
                AND (def.location_id IS NULL OR l.id = def.location_id)
              ORDER BY l.timezone);
END;
$$;
REVOKE ALL ON FUNCTION public.task_definition_generation_input(uuid)
FROM PUBLIC, anon, authenticated, operations_hub_scheduler;
GRANT EXECUTE ON FUNCTION public.task_definition_generation_input(uuid)
TO operations_hub_runtime;

-- Scheduler path: no application user exists, so no user permission check.
-- Only the scheduler role may execute these.
CREATE FUNCTION public.scheduler_active_task_definitions()
RETURNS TABLE (
    id uuid,
    recurrence_rule text,
    start_date date,
    end_date date,
    definition_version text, target_timezones text[]
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT d.id, d.recurrence_rule, d.start_date, d.end_date,
           md5((to_jsonb(d) - 'created_at' - 'updated_at')::text),
           ARRAY(SELECT DISTINCT l.timezone FROM public.locations AS l
                 WHERE l.brand_id = d.brand_id AND l.is_active
                   AND (d.location_id IS NULL OR l.id = d.location_id)
                 ORDER BY l.timezone)
    FROM public.task_definitions AS d
    JOIN public.brands AS b ON b.id = d.brand_id
    WHERE d.is_active AND b.is_active
    ORDER BY d.id;
$$;

CREATE FUNCTION public.scheduler_generate_task_instances(
    p_definition_id uuid,
    p_days date[],
    p_expected_version text,
    p_timezone text DEFAULT NULL
) RETURNS integer
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT identity_access.insert_task_occurrences(p_definition_id, p_days, p_expected_version, p_timezone);
$$;

REVOKE ALL ON FUNCTION identity_access.insert_task_occurrences(uuid, date[], text, text)
FROM PUBLIC, anon, authenticated, operations_hub_runtime, operations_hub_scheduler;
GRANT EXECUTE ON FUNCTION identity_access.insert_task_occurrences(uuid, date[], text, text)
TO operations_hub_instance_writer;

REVOKE ALL ON FUNCTION
    public.generate_task_instances(uuid, date[], text, text),
    public.scheduler_active_task_definitions(),
    public.scheduler_generate_task_instances(uuid, date[], text, text)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.generate_task_instances(uuid, date[], text, text)
TO operations_hub_runtime;
GRANT EXECUTE ON FUNCTION
    public.scheduler_active_task_definitions(),
    public.scheduler_generate_task_instances(uuid, date[], text, text)
TO operations_hub_scheduler;

-- Entry points run with the writer's narrow privileges.
GRANT CREATE ON SCHEMA public, identity_access TO operations_hub_instance_writer;
GRANT operations_hub_instance_writer TO postgres WITH INHERIT FALSE, SET TRUE;
ALTER FUNCTION public.task_definition_generation_input(uuid)
    OWNER TO operations_hub_instance_writer;
ALTER FUNCTION identity_access.insert_task_occurrences(uuid, date[], text, text)
    OWNER TO operations_hub_instance_writer;
ALTER FUNCTION public.generate_task_instances(uuid, date[], text, text)
    OWNER TO operations_hub_instance_writer;
ALTER FUNCTION public.scheduler_active_task_definitions()
    OWNER TO operations_hub_instance_writer;
ALTER FUNCTION public.scheduler_generate_task_instances(uuid, date[], text, text)
    OWNER TO operations_hub_instance_writer;
REVOKE operations_hub_instance_writer FROM postgres;
REVOKE CREATE ON SCHEMA public, identity_access FROM operations_hub_instance_writer;
