-- Definition creation only. No runtime INSERT privilege or instance generation.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles
                   WHERE rolname = 'operations_hub_definition_writer') THEN
        CREATE ROLE operations_hub_definition_writer NOLOGIN;
    END IF;
END;
$$;
ALTER ROLE operations_hub_definition_writer
    NOLOGIN NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
GRANT USAGE ON SCHEMA public, identity_access TO operations_hub_definition_writer;

-- A store permission never authorizes a brand-wide definition (NULL location).
CREATE FUNCTION identity_access.can_create_task_definition(
    target_brand_id uuid, target_location_id uuid
) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.brands AS b
        WHERE b.id = target_brand_id AND b.is_active
          AND (target_location_id IS NULL OR EXISTS (
              SELECT 1 FROM public.locations AS l
              WHERE l.id = target_location_id AND l.brand_id = b.id AND l.is_active
          ))
          AND EXISTS (
              SELECT 1 FROM identity_access.current_user_permissions() AS p
              WHERE p.permission_key = 'tasks.manage'
                AND p.organization_id = b.organization_id
                AND (
                    p.role_scope = 'organization'
                    OR (p.role_scope = 'brand' AND p.brand_id = b.id)
                    OR (p.role_scope = 'location' AND p.brand_id = b.id
                        AND p.location_id = target_location_id)
                )
          )
    );
$$;
REVOKE ALL ON FUNCTION identity_access.can_create_task_definition(uuid, uuid)
FROM PUBLIC, anon, authenticated, operations_hub_runtime;
GRANT EXECUTE ON FUNCTION identity_access.can_create_task_definition(uuid, uuid)
TO operations_hub_definition_writer;

GRANT CREATE ON SCHEMA identity_access TO operations_hub_auth_reader;
GRANT operations_hub_auth_reader TO postgres WITH INHERIT FALSE, SET TRUE;
ALTER FUNCTION identity_access.can_create_task_definition(uuid, uuid)
OWNER TO operations_hub_auth_reader;
SET ROLE operations_hub_auth_reader;
GRANT EXECUTE ON FUNCTION identity_access.current_active_user_id(),
    identity_access.current_user_organization_id()
TO operations_hub_definition_writer;
RESET ROLE;
REVOKE operations_hub_auth_reader FROM postgres;
REVOKE CREATE ON SCHEMA identity_access FROM operations_hub_auth_reader;

GRANT EXECUTE ON FUNCTION identity_access.lock_assignment_organization(),
    public.valid_task_scheduled_times(time[])
TO operations_hub_definition_writer;
GRANT SELECT ON public.task_definitions TO operations_hub_definition_writer;
GRANT INSERT (
    brand_id, location_id, created_by, name, description, category,
    recurrence_rule, start_date, end_date, schedule_mode, scheduled_times,
    due_time, numeric_unit, numeric_min, numeric_max
) ON public.task_definitions TO operations_hub_definition_writer;

CREATE POLICY task_definition_writer_insert ON public.task_definitions
FOR INSERT TO operations_hub_definition_writer
WITH CHECK (
    created_by = (SELECT identity_access.current_active_user_id())
    AND identity_access.can_create_task_definition(brand_id, location_id)
);
-- Needed for INSERT RETURNING, not a public definition-list policy.
CREATE POLICY task_definition_writer_select ON public.task_definitions
FOR SELECT TO operations_hub_definition_writer
USING (
    created_by = (SELECT identity_access.current_active_user_id())
    AND identity_access.can_create_task_definition(brand_id, location_id)
);

CREATE FUNCTION identity_access.create_task_definition(
    p_brand_id uuid,
    p_location_id uuid,
    p_name text,
    p_description text,
    p_category text,
    p_recurrence_rule text,
    p_start_date date,
    p_end_date date,
    p_schedule_mode text,
    p_scheduled_times time[],
    p_due_time time,
    p_numeric_unit text,
    p_numeric_min numeric,
    p_numeric_max numeric
) RETURNS public.task_definitions
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    result public.task_definitions;
BEGIN
    -- Serialize with role-assignment changes and recheck permissions after waiting.
    -- Reuses the identity writer convention; requires READ COMMITTED.
    PERFORM identity_access.lock_assignment_organization();
    IF NOT identity_access.can_create_task_definition(p_brand_id, p_location_id) THEN
        -- Missing, inactive, mismatched and unauthorized targets have one response.
        RAISE EXCEPTION 'Task definition creation is not authorized'
            USING ERRCODE = '42501';
    END IF;

    -- Full RRULE semantics are validated by the trusted backend library.
    -- SQL CHECKs enforce structural, scheduling and numeric invariants here.
    INSERT INTO public.task_definitions (
        brand_id, location_id, created_by, name, description, category,
        recurrence_rule, start_date, end_date, schedule_mode, scheduled_times,
        due_time, numeric_unit, numeric_min, numeric_max
    ) VALUES (
        p_brand_id, p_location_id, identity_access.current_active_user_id(),
        p_name, p_description, p_category, p_recurrence_rule,
        p_start_date, p_end_date, p_schedule_mode, p_scheduled_times,
        p_due_time, p_numeric_unit, p_numeric_min, p_numeric_max
    ) RETURNING * INTO result;
    RETURN result;
END;
$$;
REVOKE ALL ON FUNCTION identity_access.create_task_definition(
    uuid, uuid, text, text, text, text, date, date, text, time[], time, text, numeric, numeric
) FROM PUBLIC, anon, authenticated, operations_hub_runtime;
GRANT EXECUTE ON FUNCTION identity_access.create_task_definition(
    uuid, uuid, text, text, text, text, date, date, text, time[], time, text, numeric, numeric
) TO operations_hub_runtime;

GRANT CREATE ON SCHEMA identity_access TO operations_hub_definition_writer;
GRANT operations_hub_definition_writer TO postgres WITH INHERIT FALSE, SET TRUE;
ALTER FUNCTION identity_access.create_task_definition(
    uuid, uuid, text, text, text, text, date, date, text, time[], time, text, numeric, numeric
) OWNER TO operations_hub_definition_writer;
REVOKE operations_hub_definition_writer FROM postgres;
REVOKE CREATE ON SCHEMA identity_access FROM operations_hub_definition_writer;
