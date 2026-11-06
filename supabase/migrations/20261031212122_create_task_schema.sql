-- Schema foundation only. Read policies, authorized write functions, and
-- instance generation are separate migrations. No runtime writes are granted.

CREATE TABLE public.task_definitions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    brand_id uuid NOT NULL,
    location_id uuid,
    created_by uuid NOT NULL,
    name text NOT NULL,
    description text NOT NULL,
    category text NOT NULL,
    -- Canonical RRULE value without the RRULE: prefix. NULL means one-off.
    -- Semantic validation must be implemented by the recurrence API/materializer using a library.
    recurrence_rule text,
    start_date date NOT NULL,
    end_date date,
    due_time time,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    -- Numeric-only MVP assumption. Bounds reject invalid input, not abnormal readings.
    requires_numeric_value boolean NOT NULL DEFAULT false,
    numeric_unit text,
    numeric_min numeric,
    numeric_max numeric,

    CONSTRAINT task_definitions_numeric_disabled_check CHECK (
        requires_numeric_value OR (numeric_unit IS NULL AND numeric_min IS NULL AND numeric_max IS NULL)
    ),
    CONSTRAINT task_definitions_numeric_unit_check CHECK (numeric_unit IS NULL OR numeric_unit ~ '[^[:space:]]'),
    CONSTRAINT task_definitions_numeric_bounds_check CHECK (numeric_min IS NULL OR numeric_max IS NULL OR numeric_min <= numeric_max),
    CONSTRAINT task_definitions_numeric_finite_check CHECK (
        (numeric_min IS NULL OR numeric_min NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric))
        AND (numeric_max IS NULL OR numeric_max NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric))
    ),
    CONSTRAINT task_definitions_id_brand_unique UNIQUE (id, brand_id),
    CONSTRAINT task_definitions_brand_fk FOREIGN KEY (brand_id)
        REFERENCES public.brands (id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    -- MATCH SIMPLE permits a null location for a brand-wide definition.
    CONSTRAINT task_definitions_location_brand_fk FOREIGN KEY (location_id, brand_id)
        REFERENCES public.locations (id, brand_id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT task_definitions_creator_fk FOREIGN KEY (created_by)
        REFERENCES public.users (id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT task_definitions_name_check CHECK (name ~ '[^[:space:]]'),
    CONSTRAINT task_definitions_category_check CHECK (category IN ('Opening', 'Midday', 'Closing')),
    -- Structural guard only: this is not a complete RRULE parser.
    CONSTRAINT task_definitions_recurrence_rule_check CHECK (
        recurrence_rule IS NULL OR (
            length(recurrence_rule) BETWEEN 10 AND 512
            AND recurrence_rule ~ '^FREQ=(DAILY|WEEKLY|MONTHLY|YEARLY)(;[A-Z]+=[A-Z0-9,+-]+)*$'
            AND recurrence_rule !~ ';(DTSTART|TZID|UNTIL|BYHOUR|BYMINUTE|BYSECOND|RDATE|EXDATE|EXRULE|RRULE)='
        )
    ),
    CONSTRAINT task_definitions_date_bounds_check CHECK (
        start_date BETWEEN DATE '2000-01-01' AND DATE '2199-12-31'
        AND (end_date IS NULL OR end_date BETWEEN DATE '2000-01-01' AND DATE '2199-12-31')
    ),
    CONSTRAINT task_definitions_date_range_check CHECK (end_date IS NULL OR end_date >= start_date),
    CONSTRAINT task_definitions_one_off_check CHECK (recurrence_rule IS NOT NULL OR end_date IS NULL)
);

CREATE TABLE public.task_instances (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    brand_id uuid NOT NULL,
    location_id uuid NOT NULL,
    definition_id uuid NOT NULL,
    scheduled_day date NOT NULL,
    name_snapshot text NOT NULL,
    description_snapshot text NOT NULL,
    category_snapshot text NOT NULL,
    due_time_snapshot time,
    timezone_snapshot text NOT NULL,
    completed_at timestamptz,
    completed_by uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    -- Materialization must explicitly copy the definition configuration.
    requires_numeric_value_snapshot boolean NOT NULL,
    numeric_unit_snapshot text,
    numeric_min_snapshot numeric,
    numeric_max_snapshot numeric,
    recorded_value numeric,

    CONSTRAINT task_instances_numeric_disabled_check CHECK (
        requires_numeric_value_snapshot OR (numeric_unit_snapshot IS NULL AND numeric_min_snapshot IS NULL AND numeric_max_snapshot IS NULL)
    ),
    CONSTRAINT task_instances_numeric_unit_check CHECK (numeric_unit_snapshot IS NULL OR numeric_unit_snapshot ~ '[^[:space:]]'),
    CONSTRAINT task_instances_numeric_bounds_check CHECK (numeric_min_snapshot IS NULL OR numeric_max_snapshot IS NULL OR numeric_min_snapshot <= numeric_max_snapshot),
    CONSTRAINT task_instances_numeric_finite_check CHECK (
        (numeric_min_snapshot IS NULL OR numeric_min_snapshot NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric))
        AND (numeric_max_snapshot IS NULL OR numeric_max_snapshot NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric))
    ),
    -- No draft readings: completion, actor and required value are written together.
    CONSTRAINT task_instances_value_presence_check CHECK (
        (completed_at IS NULL AND recorded_value IS NULL)
        OR (completed_at IS NOT NULL AND (
            (requires_numeric_value_snapshot AND recorded_value IS NOT NULL)
            OR (NOT requires_numeric_value_snapshot AND recorded_value IS NULL)
        ))
    ),
    CONSTRAINT task_instances_value_finite_check CHECK (
        recorded_value IS NULL OR recorded_value NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)
    ),
    CONSTRAINT task_instances_value_range_check CHECK (
        recorded_value IS NULL OR (
            (numeric_min_snapshot IS NULL OR recorded_value >= numeric_min_snapshot)
            AND (numeric_max_snapshot IS NULL OR recorded_value <= numeric_max_snapshot)
        )
    ),
    CONSTRAINT task_instances_brand_fk FOREIGN KEY (brand_id)
        REFERENCES public.brands (id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT task_instances_location_brand_fk FOREIGN KEY (location_id, brand_id)
        REFERENCES public.locations (id, brand_id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT task_instances_definition_brand_fk FOREIGN KEY (definition_id, brand_id)
        REFERENCES public.task_definitions (id, brand_id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT task_instances_completer_fk FOREIGN KEY (completed_by)
        REFERENCES public.users (id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT task_instances_occurrence_unique UNIQUE (definition_id, location_id, scheduled_day),
    CONSTRAINT task_instances_name_check CHECK (name_snapshot ~ '[^[:space:]]'),
    CONSTRAINT task_instances_category_check CHECK (category_snapshot IN ('Opening', 'Midday', 'Closing')),
    CONSTRAINT task_instances_timezone_check CHECK (timezone_snapshot ~ '[^[:space:]]'),
    CONSTRAINT task_instances_completion_check CHECK ((completed_at IS NULL) = (completed_by IS NULL))
);

CREATE TABLE public.task_instance_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    instance_id uuid NOT NULL,
    actor_id uuid NOT NULL,
    event_type text NOT NULL,
    occurred_at timestamptz NOT NULL DEFAULT now(),
    -- Completion events preserve the submitted reading when an instance reopens.
    -- Reopened events carry no new reading; the earlier completion event retains it.
    recorded_value numeric,

    CONSTRAINT task_instance_events_value_type_check CHECK (event_type = 'completed' OR recorded_value IS NULL),
    CONSTRAINT task_instance_events_value_finite_check CHECK (
        recorded_value IS NULL OR recorded_value NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)
    ),

    CONSTRAINT task_instance_events_instance_fk FOREIGN KEY (instance_id)
        REFERENCES public.task_instances (id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT task_instance_events_actor_fk FOREIGN KEY (actor_id)
        REFERENCES public.users (id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT task_instance_events_type_check CHECK (event_type IN ('completed', 'reopened'))
);

CREATE INDEX task_definitions_brand_location_idx ON public.task_definitions (brand_id, location_id);
CREATE INDEX task_definitions_creator_idx ON public.task_definitions (created_by);
CREATE INDEX task_instances_location_day_idx ON public.task_instances (location_id, scheduled_day);
CREATE INDEX task_instances_brand_day_idx ON public.task_instances (brand_id, scheduled_day);
CREATE INDEX task_instances_completer_idx ON public.task_instances (completed_by);
CREATE INDEX task_instance_events_instance_time_idx ON public.task_instance_events (instance_id, occurred_at);
CREATE INDEX task_instance_events_actor_idx ON public.task_instance_events (actor_id);

CREATE TRIGGER task_definitions_set_updated_at
BEFORE UPDATE ON public.task_definitions
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER task_instances_set_updated_at
BEFORE UPDATE ON public.task_instances
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.task_definitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_instances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_instance_events ENABLE ROW LEVEL SECURITY;

-- Override any environment-specific default grants. Runtime access remains
-- denied until policies are added; event writes will use controlled functions.
REVOKE ALL ON public.task_definitions, public.task_instances, public.task_instance_events
FROM PUBLIC, anon, authenticated, operations_hub_runtime;
GRANT SELECT ON public.task_definitions, public.task_instances
TO operations_hub_runtime;

-- Still required in authorized write paths: actor/organization checks,
-- location-specific definition targeting, schedule eligibility, snapshot copying,
-- numeric configuration copying/immutability, event value matching,
-- and atomic completion/reopening with append-only audit events. Foreign keys
-- alone do not implement these business rules.
