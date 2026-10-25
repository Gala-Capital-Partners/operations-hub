-- Extend the helper owner's read access only to columns needed
-- to resolve role grants and active targets.

GRANT SELECT (id, key, scope)
ON public.roles
TO operations_hub_auth_reader;

GRANT SELECT (id, key)
ON public.permissions
TO operations_hub_auth_reader;

GRANT SELECT (role_id, permission_id)
ON public.role_permissions
TO operations_hub_auth_reader;

GRANT SELECT (
    user_id, organization_id, role_id, role_scope, brand_id
)
ON public.user_roles
TO operations_hub_auth_reader;

GRANT SELECT (
    user_id, organization_id, brand_id,
    location_id, role_id, role_scope
)
ON public.user_locations
TO operations_hub_auth_reader;

GRANT SELECT (id, organization_id, is_active)
ON public.brands
TO operations_hub_auth_reader;

GRANT SELECT (id, brand_id, is_active)
ON public.locations
TO operations_hub_auth_reader;

-- Returns grants for the current active user only.
-- This is authorization input, not a complete access decision:
-- self-only reads and role-assignment restrictions still require checks.
CREATE FUNCTION identity_access.current_user_permissions()
RETURNS TABLE (
    role_key text,
    permission_key text,
    role_scope text,
    organization_id uuid,
    brand_id uuid,
    location_id uuid
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    -- Organization and brand assignments.
    SELECT
        r.key,
        p.key,
        ur.role_scope,
        ur.organization_id,
        ur.brand_id,
        NULL::uuid
    FROM public.user_roles AS ur
    JOIN public.roles AS r
        ON r.id = ur.role_id
       AND r.scope = ur.role_scope
    JOIN public.role_permissions AS rp
        ON rp.role_id = r.id
    JOIN public.permissions AS p
        ON p.id = rp.permission_id
    LEFT JOIN public.brands AS b
        ON b.id = ur.brand_id
       AND b.organization_id = ur.organization_id
    WHERE ur.user_id = identity_access.current_active_user_id()
      AND (
          ur.role_scope = 'organization'
          OR (
              ur.role_scope = 'brand'
              AND b.is_active = true
          )
      )

    UNION ALL

    -- Location assignments require an active brand and location.
    SELECT
        r.key,
        p.key,
        ul.role_scope,
        ul.organization_id,
        ul.brand_id,
        ul.location_id
    FROM public.user_locations AS ul
    JOIN public.roles AS r
        ON r.id = ul.role_id
       AND r.scope = ul.role_scope
    JOIN public.role_permissions AS rp
        ON rp.role_id = r.id
    JOIN public.permissions AS p
        ON p.id = rp.permission_id
    JOIN public.brands AS b
        ON b.id = ul.brand_id
       AND b.organization_id = ul.organization_id
    JOIN public.locations AS l
        ON l.id = ul.location_id
       AND l.brand_id = ul.brand_id
    WHERE ul.user_id = identity_access.current_active_user_id()
      AND b.is_active = true
      AND l.is_active = true;
$$;

REVOKE ALL ON FUNCTION identity_access.current_user_permissions()
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION identity_access.current_user_permissions()
TO operations_hub_runtime;

GRANT CREATE ON SCHEMA identity_access
TO operations_hub_auth_reader;

GRANT operations_hub_auth_reader TO postgres
WITH INHERIT FALSE, SET TRUE;

ALTER FUNCTION identity_access.current_user_permissions()
OWNER TO operations_hub_auth_reader;

REVOKE operations_hub_auth_reader FROM postgres;

REVOKE CREATE ON SCHEMA identity_access
FROM operations_hub_auth_reader;