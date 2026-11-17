-- Only these entry points may change task completion state. Identity comes from
-- app.user_id set by the authenticated backend, never from a supplied actor ID.
CREATE ROLE operations_hub_task_writer
    NOLOGIN NOINHERIT NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;

GRANT USAGE ON SCHEMA public, identity_access
TO operations_hub_task_writer;

GRANT SELECT ON public.task_instances
TO operations_hub_task_writer;

GRANT UPDATE (completed_at, completed_by, recorded_value, notes)
ON public.task_instances
TO operations_hub_task_writer;

GRANT INSERT ON public.task_instance_events
TO operations_hub_task_writer;

CREATE POLICY task_instances_writer_select
ON public.task_instances
FOR SELECT TO operations_hub_task_writer
USING (true);

CREATE POLICY task_instances_writer_update
ON public.task_instances
FOR UPDATE TO operations_hub_task_writer
USING (true)
WITH CHECK (true);

CREATE POLICY task_events_writer_insert
ON public.task_instance_events
FOR INSERT TO operations_hub_task_writer
WITH CHECK (true);

GRANT operations_hub_auth_reader TO postgres
WITH INHERIT FALSE, SET TRUE;

SET ROLE operations_hub_auth_reader;

GRANT EXECUTE ON FUNCTION
    identity_access.current_active_user_id(),
    identity_access.current_user_organization_id(),
    identity_access.current_location_ids_with(text)
TO operations_hub_task_writer;

RESET ROLE;
REVOKE operations_hub_auth_reader FROM postgres;

GRANT EXECUTE ON FUNCTION identity_access.lock_assignment_organization()
TO operations_hub_task_writer;

CREATE FUNCTION identity_access.change_task_completion(
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

REVOKE ALL
ON FUNCTION identity_access.change_task_completion(uuid, boolean, numeric, text)
FROM PUBLIC, anon, authenticated, operations_hub_runtime;

GRANT EXECUTE
ON FUNCTION identity_access.change_task_completion(uuid, boolean, numeric, text)
TO operations_hub_task_writer;

CREATE FUNCTION public.complete_task_instance(
    p_instance_id uuid,
    p_value numeric DEFAULT NULL,
    p_notes text DEFAULT NULL
)
RETURNS public.task_instances
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT identity_access.change_task_completion(
        p_instance_id, true, p_value, p_notes
    );
$$;

CREATE FUNCTION public.reopen_task_instance(p_instance_id uuid)
RETURNS public.task_instances
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT identity_access.change_task_completion(
        p_instance_id, false, NULL, NULL
    );
$$;

REVOKE ALL ON FUNCTION
    public.complete_task_instance(uuid, numeric, text),
    public.reopen_task_instance(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
    public.complete_task_instance(uuid, numeric, text),
    public.reopen_task_instance(uuid)
TO operations_hub_runtime;

GRANT CREATE ON SCHEMA public TO operations_hub_task_writer;
GRANT operations_hub_task_writer TO postgres
WITH INHERIT FALSE, SET TRUE;

ALTER FUNCTION public.complete_task_instance(uuid, numeric, text)
OWNER TO operations_hub_task_writer;

ALTER FUNCTION public.reopen_task_instance(uuid)
OWNER TO operations_hub_task_writer;

REVOKE operations_hub_task_writer FROM postgres;
REVOKE CREATE ON SCHEMA public FROM operations_hub_task_writer;
