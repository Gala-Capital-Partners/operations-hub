-- Returns the active caller's organization, including during onboarding.
-- Organization membership permits reading organization details only;
-- it does not grant access to brands, locations, or other users.
CREATE FUNCTION identity_access.current_user_organization_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT u.organization_id
    FROM public.users AS u
    WHERE u.id = identity_access.current_active_user_id();
$$;

-- Keep the helper private to the backend runtime role.
REVOKE ALL
ON FUNCTION identity_access.current_user_organization_id()
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION identity_access.current_user_organization_id()
TO operations_hub_runtime;

-- Temporarily grant the privileges needed to transfer ownership.
GRANT CREATE ON SCHEMA identity_access
TO operations_hub_auth_reader;

GRANT operations_hub_auth_reader TO postgres
WITH INHERIT FALSE, SET TRUE;

ALTER FUNCTION identity_access.current_user_organization_id()
OWNER TO operations_hub_auth_reader;

-- Remove the temporary privileges.
REVOKE operations_hub_auth_reader FROM postgres;

REVOKE CREATE ON SCHEMA identity_access
FROM operations_hub_auth_reader;

-- Table privileges permit SELECT; RLS determines which rows are visible.
GRANT SELECT ON public.organizations
TO operations_hub_runtime;

CREATE POLICY organizations_select_own
ON public.organizations
FOR SELECT
TO operations_hub_runtime
USING (
    id = (
        SELECT identity_access.current_user_organization_id()
    )
);

-- Brand discovery does not grant access to every location in that brand.
CREATE FUNCTION identity_access.current_user_brand_ids()
RETURNS SETOF uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT b.id
    FROM public.brands AS b
    WHERE b.is_active = true
      AND (
          -- Organization and brand assignments.
          EXISTS (
              SELECT 1
              FROM public.user_roles AS ur
              WHERE ur.user_id =
                    identity_access.current_active_user_id()
                AND ur.organization_id = b.organization_id
                AND (
                    ur.role_scope = 'organization'
                    OR (
                        ur.role_scope = 'brand'
                        AND ur.brand_id = b.id
                    )
                )
          )

          OR

          -- A location assignment makes its parent brand discoverable.
          EXISTS (
              SELECT 1
              FROM public.user_locations AS ul
              JOIN public.locations AS l
                ON l.id = ul.location_id
               AND l.brand_id = ul.brand_id
              WHERE ul.user_id =
                    identity_access.current_active_user_id()
                AND ul.organization_id = b.organization_id
                AND ul.brand_id = b.id
                AND l.is_active = true
          )
      );
$$;

-- Keep the helper private to the backend runtime role.
REVOKE ALL
ON FUNCTION identity_access.current_user_brand_ids()
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION identity_access.current_user_brand_ids()
TO operations_hub_runtime;

-- Temporarily grant the privileges needed to transfer ownership.
GRANT CREATE ON SCHEMA identity_access
TO operations_hub_auth_reader;

GRANT operations_hub_auth_reader TO postgres
WITH INHERIT FALSE, SET TRUE;

ALTER FUNCTION identity_access.current_user_brand_ids()
OWNER TO operations_hub_auth_reader;

-- Remove the temporary privileges.
REVOKE operations_hub_auth_reader FROM postgres;

REVOKE CREATE ON SCHEMA identity_access
FROM operations_hub_auth_reader;

-- Table privileges permit SELECT; RLS determines which rows are visible.
GRANT SELECT ON public.brands
TO operations_hub_runtime;

CREATE POLICY brands_select_accessible
ON public.brands
FOR SELECT
TO operations_hub_runtime
USING (
    id IN (
        SELECT identity_access.current_user_brand_ids()
    )
);

-- Active users may inspect the shared authorization catalog.
-- Catalog changes remain migration-only: runtime receives SELECT only.
GRANT SELECT
ON public.roles, public.permissions, public.role_permissions
TO operations_hub_runtime;

CREATE POLICY roles_select_active_user
ON public.roles
FOR SELECT
TO operations_hub_runtime
USING (
    (SELECT identity_access.current_active_user_id()) IS NOT NULL
);

CREATE POLICY permissions_select_active_user
ON public.permissions
FOR SELECT
TO operations_hub_runtime
USING (
    (SELECT identity_access.current_active_user_id()) IS NOT NULL
);

CREATE POLICY role_permissions_select_active_user
ON public.role_permissions
FOR SELECT
TO operations_hub_runtime
USING (
    (SELECT identity_access.current_active_user_id()) IS NOT NULL
);
