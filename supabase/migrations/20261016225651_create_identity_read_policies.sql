CREATE FUNCTION identity_access.current_readable_location_ids()
RETURNS SETOF uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT l.id
    FROM public.locations AS l
    JOIN public.brands AS b
        ON b.id = l.brand_id
    WHERE l.is_active = true
      AND b.is_active = true
      AND EXISTS (
          SELECT 1
          FROM identity_access.current_user_permissions() AS p
          WHERE p.permission_key = 'locations.read'

            -- Always stay within the assignment's organization.
            AND p.organization_id = b.organization_id

            AND (
                -- Organization permission covers every brand in that org.
                p.role_scope = 'organization'

                -- Brand permission covers locations in that brand.
                OR (
                    p.role_scope = 'brand'
                    AND p.brand_id = b.id
                )

                -- Location permission covers only this specific location.
                OR (
                    p.role_scope = 'location'
                    AND p.brand_id = b.id
                    AND p.location_id = l.id
                )
            )
      );
$$;

REVOKE ALL
ON FUNCTION identity_access.current_readable_location_ids()
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION identity_access.current_readable_location_ids()
TO operations_hub_runtime;

-- Temporarily allow the ownership transfer.
GRANT CREATE ON SCHEMA identity_access
TO operations_hub_auth_reader;

GRANT operations_hub_auth_reader TO postgres
WITH INHERIT FALSE, SET TRUE;

ALTER FUNCTION identity_access.current_readable_location_ids()
OWNER TO operations_hub_auth_reader;

-- Remove the temporary privileges.
REVOKE operations_hub_auth_reader FROM postgres;

REVOKE CREATE ON SCHEMA identity_access
FROM operations_hub_auth_reader;

-- Table privileges allow the runtime role to issue SELECT.
GRANT SELECT ON public.locations
TO operations_hub_runtime;

-- Already enabled first migration; shown for clarity.
ALTER TABLE public.locations ENABLE ROW LEVEL SECURITY;

-- RLS determines which rows SELECT may return.
CREATE POLICY locations_select_scoped
ON public.locations
FOR SELECT
TO operations_hub_runtime
USING (
    id IN (
        SELECT identity_access.current_readable_location_ids()
    )
);