-- Sponsor clarification: numeric readings and free-text notes are independently
-- optional at completion. Preserve existing readings, bounds and audit history.
ALTER TABLE public.task_definitions
    DROP CONSTRAINT task_definitions_numeric_disabled_check,
    DROP COLUMN requires_numeric_value;

ALTER TABLE public.task_instances
    DROP CONSTRAINT task_instances_numeric_disabled_check,
    DROP CONSTRAINT task_instances_value_presence_check,
    DROP COLUMN requires_numeric_value_snapshot,
    ADD COLUMN notes text,
    ADD CONSTRAINT task_instances_completion_data_check CHECK (
        completed_at IS NOT NULL OR (recorded_value IS NULL AND notes IS NULL)
    ),
    ADD CONSTRAINT task_instances_notes_nonblank_check CHECK (
        notes IS NULL OR notes ~ '[^[:space:]]'
    ),
    ADD CONSTRAINT task_instances_notes_length_check CHECK (
        notes IS NULL OR char_length(notes) <= 2000
    );

ALTER TABLE public.task_instance_events
    ADD COLUMN notes text,
    ADD CONSTRAINT task_instance_events_notes_type_check CHECK (
        event_type = 'completed' OR notes IS NULL
    ),
    ADD CONSTRAINT task_instance_events_notes_nonblank_check CHECK (
        notes IS NULL OR notes ~ '[^[:space:]]'
    ),
    ADD CONSTRAINT task_instance_events_notes_length_check CHECK (
        notes IS NULL OR char_length(notes) <= 2000
    );

-- Existing finite-number and inclusive bounds checks still apply when a value
-- is provided. No draft completion data: reopening clears the current value and
-- notes, while prior completion events retain both. Future controlled functions
-- must copy the submitted data to the event and update state atomically.
-- Notes are plain text; render them as text, never trusted HTML. Future API
-- writers should normalize blank notes to NULL before persistence; the database
-- rejects non-NULL notes without a non-whitespace character. No privileges expand.
