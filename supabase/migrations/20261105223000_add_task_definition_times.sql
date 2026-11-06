-- Unreleased draft: RRULE chooses dates; the same definition row stores times.
-- Pure validation only: no table access, privileges elevated, or schedule triggers.
CREATE FUNCTION public.valid_task_scheduled_times(times time[])
RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = ''
AS $$
    SELECT CASE
        WHEN times IS NULL THEN false
        WHEN cardinality(times) = 0 THEN true
        WHEN array_ndims(times) <> 1 OR array_lower(times, 1) <> 1 THEN false
        ELSE (
            SELECT count(*) = count(value)
                AND count(*) = count(DISTINCT value)
                AND coalesce(bool_and(value < TIME '24:00'), false)
            FROM unnest(times) AS slots(value)
        )
    END;
$$;
REVOKE ALL ON FUNCTION public.valid_task_scheduled_times(time[])
FROM PUBLIC, anon, authenticated;
-- Safe pure helper; does not grant access to task definitions or task writes.
GRANT EXECUTE ON FUNCTION public.valid_task_scheduled_times(time[])
TO operations_hub_runtime;

-- Existing definitions retain all-day behavior and their optional due times.
-- Mode and times must change in the same statement, not just transaction.
ALTER TABLE public.task_definitions
    ADD COLUMN schedule_mode text NOT NULL DEFAULT 'all_day',
    ADD COLUMN scheduled_times time[] NOT NULL DEFAULT '{}'::time[],
    ADD CONSTRAINT task_definitions_schedule_mode_check
        CHECK (schedule_mode IN ('all_day', 'timed')),
    ADD CONSTRAINT task_definitions_scheduled_times_check
        CHECK (public.valid_task_scheduled_times(scheduled_times)),
    ADD CONSTRAINT task_definitions_mode_times_check CHECK (
        (schedule_mode = 'all_day' AND cardinality(scheduled_times) = 0)
        OR (schedule_mode = 'timed' AND cardinality(scheduled_times) > 0)
    ),
    -- A single daily deadline is ambiguous for multiple timed occurrences.
    ADD CONSTRAINT task_definitions_timed_due_check
        CHECK (schedule_mode = 'all_day' OR due_time IS NULL);

-- Array order carries no meaning; generators should sort local times.
-- Controlled writers must address stale edits (e.g. optimistic version checks).
-- Row-local constraints prevent invalid schedules, not lost updates.
