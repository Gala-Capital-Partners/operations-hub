CREATE POLICY task_instances_select_scoped
ON public.task_instances
FOR SELECT
TO operations_hub_runtime
USING (
    location_id IN (
        SELECT permitted.location_id
        FROM identity_access.current_location_ids_with('task_instances.read')
            AS permitted(location_id)
    )
);