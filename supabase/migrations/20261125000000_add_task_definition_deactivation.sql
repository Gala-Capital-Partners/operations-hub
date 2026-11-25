-- Task-definition deactivation.
--
-- public.deactivate_task_definition(definition) marks a definition inactive and
-- cancels its FUTURE, uncompleted occurrences. "Future" means after the
-- occurrence's own store-local today (scheduled_day vs. now() in
-- timezone_snapshot), so a brand-wide definition is evaluated per store.
-- Today's and past occurrences, completed occurrences and all completion
-- events are preserved. Cancelled rows are kept for audit, hidden from
-- checklists by the API, and can no longer be completed.
--
-- Stopping future generation needs no generator change beyond locking:
-- inactive definitions already generate nothing and the scheduler skips them.

ALTER TABLE public.task_definitions
    ADD COLUMN deactivated_at timestamptz,
    ADD COLUMN deactivated_by uuid,
    ADD CONSTRAINT task_definitions_deactivator_fk
        FOREIGN KEY (deactivated_by) REFERENCES public.users (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    ADD CONSTRAINT task_definitions_deactivation_pair_check
        CHECK ((deactivated_at IS NULL) = (deactivated_by IS NULL)),
    -- Legacy inactive rows may have no audit data; active rows never have it.
    ADD CONSTRAINT task_definitions_deactivation_state_check
        CHECK (is_active = false OR deactivated_at IS NULL);

ALTER TABLE public.task_instances
    ADD COLUMN cancelled_at timestamptz,
    ADD COLUMN cancelled_by uuid,
    ADD CONSTRAINT task_instances_canceller_fk
        FOREIGN KEY (cancelled_by) REFERENCES public.users (id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    ADD CONSTRAINT task_instances_cancellation_pair_check
        CHECK ((cancelled_at IS NULL) = (cancelled_by IS NULL)),
    -- A completed occurrence is history and is never cancelled.
    ADD CONSTRAINT task_instances_cancelled_uncompleted_check
        CHECK (cancelled_at IS NULL OR completed_at IS NULL);

CREATE INDEX task_definitions_deactivator_idx
    ON public.task_definitions (deactivated_by) WHERE deactivated_by IS NOT NULL;
CREATE INDEX task_instances_canceller_idx
    ON public.task_instances (cancelled_by) WHERE cancelled_by IS NOT NULL;

-- Dedicated writer: it can flip the activation/cancellation columns only.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles
                   WHERE rolname = 'operations_hub_deactivation_writer') THEN
        CREATE ROLE operations_hub_deactivation_writer NOLOGIN;
    END IF;
END;
$$;
ALTER ROLE operations_hub_deactivation_writer
    NOLOGIN NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
GRANT USAGE ON SCHEMA public, identity_access
TO operations_hub_deactivation_writer;

GRANT SELECT ON public.task_definitions, public.task_instances
TO operations_hub_deactivation_writer;
GRANT UPDATE (is_active, deactivated_at, deactivated_by)
ON public.task_definitions TO operations_hub_deactivation_writer;
GRANT UPDATE (cancelled_at, cancelled_by)
ON public.task_instances TO operations_hub_deactivation_writer;

-- Writer-only policies. Authorization happens in the entry point below.
CREATE POLICY task_definitions_deactivation_writer_select ON public.task_definitions
FOR SELECT TO operations_hub_deactivation_writer USING (true);
CREATE POLICY task_definitions_deactivation_writer_update ON public.task_definitions
FOR UPDATE TO operations_hub_deactivation_writer USING (true) WITH CHECK (true);
CREATE POLICY task_instances_deactivation_writer_select ON public.task_instances
FOR SELECT TO operations_hub_deactivation_writer USING (true);
CREATE POLICY task_instances_deactivation_writer_update ON public.task_instances
FOR UPDATE TO operations_hub_deactivation_writer USING (true) WITH CHECK (true);

-- Same authorization as creation (tasks.manage for the definition's target).
GRANT operations_hub_auth_reader TO postgres WITH INHERIT FALSE, SET TRUE;
SET ROLE operations_hub_auth_reader;
GRANT EXECUTE ON FUNCTION
    identity_access.can_create_task_definition(uuid, uuid),
    identity_access.current_active_user_id(),
    identity_access.current_user_organization_id()
TO operations_hub_deactivation_writer;
RESET ROLE;
REVOKE operations_hub_auth_reader FROM postgres;
-- The CHECK on scheduled_times calls this helper on every definition UPDATE.
GRANT EXECUTE ON FUNCTION identity_access.lock_assignment_organization(),
    public.valid_task_scheduled_times(time[])
TO operations_hub_deactivation_writer;

CREATE FUNCTION public.deactivate_task_definition(p_definition_id uuid)
RETURNS TABLE (
    id uuid,
    is_active boolean,
    deactivated_at timestamptz,
    cancelled_instance_count integer
)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    def public.task_definitions;
    actor uuid;
    changed_at timestamptz;
    cancelled integer;
BEGIN
    IF p_definition_id IS NULL THEN
        RAISE EXCEPTION 'Definition is required' USING ERRCODE = '22004';
    END IF;

    -- Lock order: organization (serializes with managers, completion and
    -- identity writes), then this definition (serializes with the scheduler,
    -- which holds no organization lock). Requires READ COMMITTED.
    PERFORM identity_access.lock_assignment_organization();
    PERFORM pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(
            'operations-hub:task-definition:' || p_definition_id::text, 0
        )
    );

    SELECT d.* INTO def
    FROM public.task_definitions AS d
    WHERE d.id = p_definition_id
    FOR UPDATE OF d;

    -- Missing and unauthorized definitions share one error.
    IF NOT FOUND OR NOT identity_access.can_create_task_definition(
        def.brand_id, def.location_id
    ) THEN
        RAISE EXCEPTION 'Task definition deactivation is not authorized'
            USING ERRCODE = '42501';
    END IF;

    actor := identity_access.current_active_user_id();
    IF actor IS NULL THEN
        RAISE EXCEPTION 'Task definition deactivation is not authorized'
            USING ERRCODE = '42501';
    END IF;

    -- Repeat calls succeed without changing anything.
    IF NOT def.is_active THEN
        RETURN QUERY SELECT def.id, false, def.deactivated_at, 0;
        RETURN;
    END IF;

    changed_at := clock_timestamp();

    UPDATE public.task_definitions AS d
    SET is_active = false,
        deactivated_at = changed_at,
        deactivated_by = actor
    WHERE d.id = def.id;

    -- Each occurrence is compared with ITS store's local date, so a brand-wide
    -- definition keeps today's row in every store regardless of timezone.
    UPDATE public.task_instances AS i
    SET cancelled_at = changed_at,
        cancelled_by = actor
    WHERE i.definition_id = def.id
      AND i.completed_at IS NULL
      AND i.cancelled_at IS NULL
      AND i.scheduled_day > (changed_at AT TIME ZONE i.timezone_snapshot)::date;
    GET DIAGNOSTICS cancelled = ROW_COUNT;

    RETURN QUERY SELECT def.id, false, changed_at, cancelled;
END;
$$;

REVOKE ALL ON FUNCTION public.deactivate_task_definition(uuid)
FROM PUBLIC, anon, authenticated, operations_hub_scheduler;
GRANT EXECUTE ON FUNCTION public.deactivate_task_definition(uuid)
TO operations_hub_runtime;

GRANT CREATE ON SCHEMA public TO operations_hub_deactivation_writer;
GRANT operations_hub_deactivation_writer TO postgres WITH INHERIT FALSE, SET TRUE;
ALTER FUNCTION public.deactivate_task_definition(uuid)
    OWNER TO operations_hub_deactivation_writer;
REVOKE operations_hub_deactivation_writer FROM postgres;
REVOKE CREATE ON SCHEMA public FROM operations_hub_deactivation_writer;

-- Generation takes the same per-definition lock before reading the definition.
-- Only the owner may replace it; CREATE OR REPLACE keeps owner and grants.
GRANT CREATE ON SCHEMA identity_access TO operations_hub_instance_writer;
GRANT operations_hub_instance_writer TO postgres WITH INHERIT FALSE, SET TRUE;
SET ROLE operations_hub_instance_writer;

CREATE OR REPLACE FUNCTION identity_access.insert_task_occurrences(
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

    -- Serialize with deactivation of the same definition. The scheduler holds
    -- no organization lock, so this per-definition lock is what guarantees that
    -- deactivation either sees these rows (and cancels future ones) or commits
    -- first (and this read then sees is_active = false). Advisory locks need no
    -- table privileges.
    PERFORM pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(
            'operations-hub:task-definition:' || p_definition_id::text, 0
        )
    );

    -- Fresh READ COMMITTED snapshot after a possible lock wait.
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

RESET ROLE;
REVOKE operations_hub_instance_writer FROM postgres;
REVOKE CREATE ON SCHEMA identity_access FROM operations_hub_instance_writer;

-- Reopening a future completion must not restore work for an inactive definition.
GRANT SELECT (id, is_active) ON public.task_definitions TO operations_hub_task_writer;
CREATE POLICY task_definitions_task_writer_select ON public.task_definitions
FOR SELECT TO operations_hub_task_writer USING (NOT is_active);

-- Completion rejects cancelled occurrences (function owner and grants unchanged).
-- The task writer reads cancelled_at through its existing SELECT grant.
CREATE OR REPLACE FUNCTION identity_access.change_task_completion(
    p_instance_id uuid,
    p_complete boolean,
    p_value numeric,
    p_notes text
)
RETURNS public.task_instances
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
    target public.task_instances;
    actor uuid;
    permission text;
    clean_notes text;
    changed_at timestamptz;
BEGIN
    IF p_instance_id IS NULL OR p_complete IS NULL THEN
        RAISE EXCEPTION 'Instance and action are required'
            USING ERRCODE = '22004';
    END IF;

    -- Same lock order as identity writers: organization first, instance second.
    -- Requires READ COMMITTED and rechecks active identity after waiting.
    PERFORM identity_access.lock_assignment_organization();

    permission := CASE
        WHEN p_complete THEN 'task_instances.complete'
        ELSE 'task_instances.reopen'
    END;

    SELECT i.*
    INTO target
    FROM public.task_instances i
    WHERE i.id = p_instance_id
      AND i.location_id IN (
          SELECT location_id
          FROM identity_access.current_location_ids_with(permission)
              AS permitted(location_id)
      )
    FOR UPDATE OF i;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Task operation is not authorized'
            USING ERRCODE = '42501';
    END IF;

    -- Fresh statement snapshot after a possible row-lock wait.
    actor := identity_access.current_active_user_id();

    IF actor IS NULL OR NOT EXISTS (
        SELECT 1
        FROM identity_access.current_location_ids_with(permission)
            AS permitted(location_id)
        WHERE location_id = target.location_id
    ) THEN
        RAISE EXCEPTION 'Task operation is not authorized'
            USING ERRCODE = '42501';
    END IF;

    -- Cancelled occurrences belong to a deactivated definition; they are
    -- hidden from checklists and can no longer be completed.
    IF target.cancelled_at IS NOT NULL THEN
        RAISE EXCEPTION 'Task was cancelled because its definition was deactivated'
            USING ERRCODE = '55000';
    END IF;

    IF NOT p_complete
       AND target.scheduled_day > (clock_timestamp() AT TIME ZONE target.timezone_snapshot)::date
       AND EXISTS (SELECT 1 FROM public.task_definitions d
                   WHERE d.id = target.definition_id AND NOT d.is_active) THEN
        RAISE EXCEPTION 'Cannot reopen a future occurrence of an inactive definition'
            USING ERRCODE = '55000';
    END IF;

    IF p_complete = (target.completed_at IS NOT NULL) THEN
        RAISE EXCEPTION 'Task is already in the requested state'
            USING ERRCODE = '55000';
    END IF;

    IF p_complete THEN
        clean_notes := CASE
            WHEN p_notes ~ '[^[:space:]]' THEN p_notes
            ELSE NULL
        END;

        IF char_length(clean_notes) > 2000 THEN
            RAISE EXCEPTION 'Notes exceed 2000 characters'
                USING ERRCODE = '22023';
        END IF;

        IF p_value IS NOT NULL AND (
            p_value IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)
            OR (
                target.numeric_min_snapshot IS NOT NULL
                AND p_value < target.numeric_min_snapshot
            )
            OR (
                target.numeric_max_snapshot IS NOT NULL
                AND p_value > target.numeric_max_snapshot
            )
        ) THEN
            RAISE EXCEPTION 'Recorded value is invalid or outside the accepted bounds'
                USING ERRCODE = '22023';
        END IF;
    END IF;

    changed_at := clock_timestamp();

    UPDATE public.task_instances
    SET completed_at = CASE WHEN p_complete THEN changed_at ELSE NULL END,
        completed_by = CASE WHEN p_complete THEN actor ELSE NULL END,
        recorded_value = CASE WHEN p_complete THEN p_value ELSE NULL END,
        notes = CASE WHEN p_complete THEN clean_notes ELSE NULL END
    WHERE id = p_instance_id
    RETURNING * INTO target;

    INSERT INTO public.task_instance_events(
        instance_id,
        actor_id,
        event_type,
        occurred_at,
        recorded_value,
        notes
    )
    VALUES (
        p_instance_id,
        actor,
        CASE WHEN p_complete THEN 'completed' ELSE 'reopened' END,
        changed_at,
        target.recorded_value,
        target.notes
    );

    RETURN target;
END;
$$;
