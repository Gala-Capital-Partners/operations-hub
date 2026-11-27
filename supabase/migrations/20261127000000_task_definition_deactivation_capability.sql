-- A checklist can retain occurrences after their definition becomes inactive.
-- Return only the caller's capability, including false for unknown IDs.
CREATE FUNCTION identity_access.can_deactivate_task_definition(p_definition_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT EXISTS (
        SELECT FROM public.task_definitions AS d
        WHERE d.id = p_definition_id AND d.is_active
          AND identity_access.can_create_task_definition(d.brand_id, d.location_id)
    );
$$;

REVOKE ALL ON FUNCTION identity_access.can_deactivate_task_definition(uuid)
FROM PUBLIC, anon, authenticated, operations_hub_scheduler;
GRANT EXECUTE ON FUNCTION identity_access.can_deactivate_task_definition(uuid)
TO operations_hub_runtime;

GRANT CREATE ON SCHEMA identity_access TO operations_hub_deactivation_writer;
GRANT operations_hub_deactivation_writer TO postgres WITH INHERIT FALSE, SET TRUE;
ALTER FUNCTION identity_access.can_deactivate_task_definition(uuid)
    OWNER TO operations_hub_deactivation_writer;
REVOKE operations_hub_deactivation_writer FROM postgres;
REVOKE CREATE ON SCHEMA identity_access FROM operations_hub_deactivation_writer;
