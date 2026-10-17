-- Assignment visibility is separate from profile visibility.
-- Active callers can inspect their own assignments, including inactive targets.
-- Other-user reads require role_assignments.read and active brand/location
-- targets. Historical access is not introduced by this migration.
GRANT SELECT (id) ON public.user_roles TO operations_hub_auth_reader;

CREATE FUNCTION identity_access.current_readable_user_role_ids()
RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT ur.id
    FROM public.user_roles ur
    LEFT JOIN public.brands b
      ON b.id = ur.brand_id AND b.organization_id = ur.organization_id
    WHERE identity_access.current_active_user_id() IS NOT NULL
      AND (
          ur.user_id = identity_access.current_active_user_id()
          OR (
              (ur.role_scope = 'organization' OR b.is_active = true)
              AND EXISTS (
                  SELECT 1 FROM identity_access.current_user_permissions() p
                  WHERE p.permission_key = 'role_assignments.read'
                    AND p.organization_id = ur.organization_id
                    AND (
                        p.role_scope = 'organization'
                        OR (
                            p.role_scope = 'brand'
                            AND ur.role_scope = 'brand'
                            AND p.brand_id = ur.brand_id
                        )
                    )
              )
          )
      );
$$;

-- user_locations has a composite primary key, so return both key columns.
-- Matching only user_id would leak that person's assignments in other stores.
CREATE FUNCTION identity_access.current_readable_user_location_keys()
RETURNS TABLE (user_id uuid, location_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT ul.user_id, ul.location_id
    FROM public.user_locations ul
    JOIN public.brands b ON b.id = ul.brand_id AND b.organization_id = ul.organization_id
    JOIN public.locations l ON l.id = ul.location_id AND l.brand_id = ul.brand_id
    WHERE identity_access.current_active_user_id() IS NOT NULL
      AND (
          ul.user_id = identity_access.current_active_user_id()
          OR (
              b.is_active = true AND l.is_active = true
              AND EXISTS (
                  SELECT 1 FROM identity_access.current_user_permissions() p
                  WHERE p.permission_key = 'role_assignments.read'
                    AND p.organization_id = ul.organization_id
                    AND (
                        p.role_scope = 'organization'
                        OR (p.role_scope = 'brand' AND p.brand_id = ul.brand_id)
                        OR (
                            p.role_scope = 'location'
                            AND p.role_key = 'location_manager'
                            AND p.brand_id = ul.brand_id
                            AND p.location_id = ul.location_id
                        )
                    )
              )
          )
      );
$$;

REVOKE ALL ON FUNCTION identity_access.current_readable_user_role_ids(),
    identity_access.current_readable_user_location_keys()
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION identity_access.current_readable_user_role_ids(),
    identity_access.current_readable_user_location_keys()
TO operations_hub_runtime;

-- The dedicated reader avoids policy recursion; runtime never inherits it.
GRANT CREATE ON SCHEMA identity_access TO operations_hub_auth_reader;
GRANT operations_hub_auth_reader TO postgres WITH INHERIT FALSE, SET TRUE;
ALTER FUNCTION identity_access.current_readable_user_role_ids() OWNER TO operations_hub_auth_reader;
ALTER FUNCTION identity_access.current_readable_user_location_keys() OWNER TO operations_hub_auth_reader;
REVOKE operations_hub_auth_reader FROM postgres;
REVOKE CREATE ON SCHEMA identity_access FROM operations_hub_auth_reader;

GRANT SELECT ON public.user_roles, public.user_locations TO operations_hub_runtime;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_locations ENABLE ROW LEVEL SECURITY;
CREATE POLICY user_roles_select_scoped ON public.user_roles
FOR SELECT TO operations_hub_runtime
USING (id IN (SELECT identity_access.current_readable_user_role_ids()));
CREATE POLICY user_locations_select_scoped ON public.user_locations
FOR SELECT TO operations_hub_runtime
USING ((user_id, location_id) IN (
    SELECT k.user_id, k.location_id
    FROM identity_access.current_readable_user_location_keys() k
));
