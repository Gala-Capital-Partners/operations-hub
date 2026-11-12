CREATE FUNCTION identity_access.current_location_ids_with(target_permission_key text)
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
          WHERE p.permission_key = target_permission_key

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
ON FUNCTION identity_access.current_location_ids_with(text)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION identity_access.current_location_ids_with(text)
TO operations_hub_runtime;

GRANT CREATE ON SCHEMA identity_access
TO operations_hub_auth_reader;

GRANT operations_hub_auth_reader TO postgres
WITH INHERIT FALSE, SET TRUE;

ALTER FUNCTION identity_access.current_location_ids_with(text)
OWNER TO operations_hub_auth_reader;

SET ROLE operations_hub_auth_reader;

CREATE OR REPLACE FUNCTION identity_access.current_readable_location_ids()
RETURNS SETOF uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT location_id
    FROM identity_access.current_location_ids_with('locations.read')
        AS locations(location_id);
$$;

RESET ROLE;

-- Remove the temporary privileges.
REVOKE operations_hub_auth_reader FROM postgres;

REVOKE CREATE ON SCHEMA identity_access
FROM operations_hub_auth_reader;