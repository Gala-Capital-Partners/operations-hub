-- Occurrence identity is an exact instant, separate from the local reporting day
-- and due time. Legacy date-only instances are treated as all-day occurrences.
ALTER TABLE public.task_instances
    ADD COLUMN scheduled_at timestamptz,
    ADD COLUMN is_all_day_snapshot boolean;

-- This deliberately fails for invalid zones/skipped local dates rather than
-- silently assigning a different local day. Resolve such legacy data first.
UPDATE public.task_instances
SET scheduled_at = scheduled_day::timestamp AT TIME ZONE timezone_snapshot,
    is_all_day_snapshot = true;

ALTER TABLE public.task_instances
    ALTER COLUMN scheduled_at SET NOT NULL,
    ALTER COLUMN is_all_day_snapshot SET NOT NULL,
    ADD CONSTRAINT task_instances_scheduled_at_finite_check CHECK (isfinite(scheduled_at)),
    ADD CONSTRAINT task_instances_local_day_check CHECK (
        scheduled_day = (scheduled_at AT TIME ZONE timezone_snapshot)::date
    ),
    ADD CONSTRAINT task_instances_all_day_anchor_check CHECK (
        NOT is_all_day_snapshot
        OR scheduled_at = (scheduled_day::timestamp AT TIME ZONE timezone_snapshot)
    ),
    DROP CONSTRAINT task_instances_occurrence_unique,
    ADD CONSTRAINT task_instances_occurrence_unique
        UNIQUE (definition_id, location_id, scheduled_at);

-- An all-day occurrence stays unique even if its timezone snapshot changes.
CREATE UNIQUE INDEX task_instances_all_day_unique
    ON public.task_instances (definition_id, location_id, scheduled_day)
    WHERE is_all_day_snapshot;

-- No defaults: the generator must choose the instant and all-day flag explicitly.
-- Controlled writes must validate IANA zones, preserve snapshots and reject
-- unintended mixing of all-day/timed schedules during definition edits.
