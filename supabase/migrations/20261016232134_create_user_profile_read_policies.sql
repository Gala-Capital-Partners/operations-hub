-- The helper owner needs organization_id to enforce the tenant boundary.
GRANT SELECT (organization_id)
ON public.users TO operations_hub_auth_reader;

-- Profile visibility does not grant access to the target user's assignments.
-- Inactive callers see nothing. Inactive target profiles remain visible to
-- authorized administrators/managers for directory and account management.
CREATE FUNCTION identity_access.current_readable_user_ids()
RETURNS SETOF uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT u.id
    FROM public.users AS u
    WHERE identity_access.current_active_user_id() IS NOT NULL
      AND (
          -- Own profile remains available during onboarding, before assignment.
          u.id = identity_access.current_active_user_id()
          OR EXISTS (
              SELECT 1
              FROM identity_access.current_user_permissions() AS p
              WHERE p.permission_key = 'users.read'
                AND p.organization_id = u.organization_id
                AND (
                    -- Includes users in this organization awaiting assignment.
                    p.role_scope = 'organization'
                    OR (
                        p.role_scope = 'brand'
                        AND (
                            -- An organization assignment covers this brand too.
                            EXISTS (
                                SELECT 1
                                FROM public.user_roles AS target_role
                                WHERE target_role.user_id = u.id
                                  AND target_role.organization_id = p.organization_id
                                  AND (
                                      target_role.role_scope = 'organization'
                                      OR (
                                          target_role.role_scope = 'brand'
                                          AND target_role.brand_id = p.brand_id
                                      )
                                  )
                            )
                            OR EXISTS (
                                SELECT 1
                                FROM public.user_locations AS target_location
                                JOIN public.locations AS l
                                  ON l.id = target_location.location_id
                                 AND l.brand_id = target_location.brand_id
                                WHERE target_location.user_id = u.id
                                  AND target_location.organization_id = p.organization_id
                                  AND target_location.brand_id = p.brand_id
                                  AND l.is_active = true
                            )
                        )
                    )
                    OR (
                        -- Employee users.read is self-only; it must not enter
                        -- this branch just because its scope is location.
                        p.role_scope = 'location'
                        AND p.role_key = 'location_manager'
                        AND EXISTS (
                            SELECT 1
                            FROM public.user_locations AS target_location
                            WHERE target_location.user_id = u.id
                              AND target_location.organization_id = p.organization_id
                              AND target_location.brand_id = p.brand_id
                              AND target_location.location_id = p.location_id
                        )
                    )
                )
          )
      );
$$;

-- Caller grants already exclude inactive brands and location targets.
-- EXISTS keeps each target profile unique even with overlapping assignments.
REVOKE ALL ON FUNCTION identity_access.current_readable_user_ids()
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION identity_access.current_readable_user_ids()
TO operations_hub_runtime;

-- Transfer ownership using temporary privileges, then remove them.
GRANT CREATE ON SCHEMA identity_access TO operations_hub_auth_reader;
GRANT operations_hub_auth_reader TO postgres WITH INHERIT FALSE, SET TRUE;
ALTER FUNCTION identity_access.current_readable_user_ids()
OWNER TO operations_hub_auth_reader;
REVOKE operations_hub_auth_reader FROM postgres;
REVOKE CREATE ON SCHEMA identity_access FROM operations_hub_auth_reader;

-- Table privileges permit reads; RLS restricts the visible profiles.
GRANT SELECT ON public.users TO operations_hub_runtime;
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

CREATE POLICY users_select_scoped
ON public.users
FOR SELECT
TO operations_hub_runtime
USING (
    id IN (SELECT identity_access.current_readable_user_ids())
);
