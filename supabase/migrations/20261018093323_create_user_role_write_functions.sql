-- Determines whether the caller may manage an organization or brand
-- assignment for another user. Does not perform the assignment change.
CREATE FUNCTION identity_access.can_manage_user_role(
    target_user_id uuid,
    target_role_id uuid,
    target_brand_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.users AS target_user
        JOIN public.roles AS target_role
          ON target_role.id = target_role_id
        WHERE target_user.id = target_user_id

          -- Require an active caller and forbid self-changes.
          AND identity_access.current_active_user_id() IS NOT NULL
          AND target_user.id <>
              identity_access.current_active_user_id()

          -- Only the approved organization and brand roles are supported.
          AND (
              (
                  target_role.key = 'org_admin'
                  AND target_role.scope = 'organization'
                  AND target_brand_id IS NULL
              )
              OR (
                  target_role.key = 'brand_admin'
                  AND target_role.scope = 'brand'
                  AND target_brand_id IS NOT NULL
                  AND EXISTS (
                      SELECT 1
                      FROM public.brands AS target_brand
                      WHERE target_brand.id = target_brand_id
                        AND target_brand.organization_id =
                            target_user.organization_id
                  )
              )
          )

          -- Only an Organization Admin in the target user's organization
          -- may manage these assignments.
          AND EXISTS (
              SELECT 1
              FROM identity_access.current_user_permissions() AS p
              WHERE p.permission_key = 'role_assignments.manage'
                AND p.role_key = 'org_admin'
                AND p.role_scope = 'organization'
                AND p.organization_id = target_user.organization_id
          )
    );
$$;

-- Keep this helper internal.
REVOKE ALL
ON FUNCTION identity_access.can_manage_user_role(uuid, uuid, uuid)
FROM PUBLIC, anon, authenticated, operations_hub_runtime;

-- Controlled write functions will run as this existing writer role.
GRANT EXECUTE
ON FUNCTION identity_access.can_manage_user_role(uuid, uuid, uuid)
TO operations_hub_assignment_writer;

-- Transfer ownership to the restricted authorization reader.
GRANT CREATE ON SCHEMA identity_access
TO operations_hub_auth_reader;

GRANT operations_hub_auth_reader TO postgres
WITH INHERIT FALSE, SET TRUE;

ALTER FUNCTION identity_access.can_manage_user_role(uuid, uuid, uuid)
OWNER TO operations_hub_auth_reader;

REVOKE operations_hub_auth_reader FROM postgres;

REVOKE CREATE ON SCHEMA identity_access
FROM operations_hub_auth_reader;

-- Extend audit targets beyond individual locations.
-- Existing records and existing location-write functions use
-- the default location scope.
ALTER TABLE identity_access.assignment_audit_log
    ADD COLUMN assignment_scope text NOT NULL DEFAULT 'location',
    ADD COLUMN brand_id uuid,
    ALTER COLUMN location_id DROP NOT NULL;

-- Each audit record identifies exactly one kind of assignment target.
ALTER TABLE identity_access.assignment_audit_log
    ADD CONSTRAINT assignment_audit_scope_target_check
    CHECK (
        (
            assignment_scope = 'organization'
            AND brand_id IS NULL
            AND location_id IS NULL
        )
        OR (
            assignment_scope = 'brand'
            AND brand_id IS NOT NULL
            AND location_id IS NULL
        )
        OR (
            assignment_scope = 'location'
            AND brand_id IS NULL
            AND location_id IS NOT NULL
        )
    );

-- The controlled writer can inspect and delete assignments.
GRANT SELECT, DELETE
ON public.user_roles
TO operations_hub_assignment_writer;

-- IDs and timestamps use their database defaults.
GRANT INSERT (
    user_id,
    organization_id,
    role_id,
    role_scope,
    brand_id
)
ON public.user_roles
TO operations_hub_assignment_writer;

-- Allow controlled functions to inspect assignments only within
-- the active caller's organization.
CREATE POLICY user_roles_writer_select
ON public.user_roles
FOR SELECT
TO operations_hub_assignment_writer
USING (
    organization_id = (
        SELECT identity_access.current_user_organization_id()
    )
);

-- New assignments must satisfy the approved authorization rules.
CREATE POLICY user_roles_writer_insert
ON public.user_roles
FOR INSERT
TO operations_hub_assignment_writer
WITH CHECK (
    identity_access.can_manage_user_role(
        user_id,
        role_id,
        brand_id
    )
);

-- Removing an assignment requires authority over that assignment.
CREATE POLICY user_roles_writer_delete
ON public.user_roles
FOR DELETE
TO operations_hub_assignment_writer
USING (
    identity_access.can_manage_user_role(
        user_id,
        role_id,
        brand_id
    )
);

-- Resolve target details within the active caller's organization.
-- This lookup does not authorize an assignment change.
CREATE FUNCTION identity_access.user_role_target(
    target_user_id uuid,
    target_brand_id uuid
)
RETURNS TABLE (
    organization_id uuid,
    user_is_active boolean,
    brand_is_active boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT
        u.organization_id,
        u.is_active,
        b.is_active
    FROM public.users AS u
    LEFT JOIN public.brands AS b
      ON b.id = target_brand_id
     AND b.organization_id = u.organization_id
    WHERE u.id = target_user_id
      AND u.organization_id = (
          SELECT identity_access.current_user_organization_id()
      )
      AND (
          target_brand_id IS NULL
          OR b.id IS NOT NULL
      );
$$;

REVOKE ALL
ON FUNCTION identity_access.user_role_target(uuid, uuid)
FROM PUBLIC, anon, authenticated, operations_hub_runtime;

GRANT EXECUTE
ON FUNCTION identity_access.user_role_target(uuid, uuid)
TO operations_hub_assignment_writer;

-- The reader already has SELECT access to the required columns.
GRANT CREATE ON SCHEMA identity_access
TO operations_hub_auth_reader;

GRANT operations_hub_auth_reader TO postgres
WITH INHERIT FALSE, SET TRUE;

ALTER FUNCTION identity_access.user_role_target(uuid, uuid)
OWNER TO operations_hub_auth_reader;

REVOKE operations_hub_auth_reader FROM postgres;

REVOKE CREATE ON SCHEMA identity_access
FROM operations_hub_auth_reader;

CREATE FUNCTION identity_access.grant_user_role(
    p_target_user_id uuid,
    p_role_id uuid,
    p_brand_id uuid,
    p_request_id uuid
)
RETURNS text
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_organization_id uuid;
    v_actor_id uuid;
    v_target record;
    v_role_scope text;
    v_affected_rows bigint;
BEGIN
    -- A NULL brand is valid for organization-scoped assignments.
    IF p_target_user_id IS NULL
       OR p_role_id IS NULL
       OR p_request_id IS NULL THEN
        RAISE EXCEPTION 'User, role, and request ID are required'
            USING ERRCODE = '22004';
    END IF;

    -- Serialize cooperating identity changes in this organization.
    v_organization_id :=
        identity_access.lock_assignment_organization();

    v_actor_id := identity_access.current_active_user_id();

    -- Authorize before revealing target details.
    IF NOT identity_access.can_manage_user_role(
        p_target_user_id,
        p_role_id,
        p_brand_id
    ) THEN
        RAISE EXCEPTION 'Assignment change is not authorized'
            USING ERRCODE = '42501';
    END IF;

    SELECT *
    INTO v_target
    FROM identity_access.user_role_target(
        p_target_user_id,
        p_brand_id
    );

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Target is unavailable or not authorized'
            USING ERRCODE = '42501';
    END IF;

    -- Organization assignments have no brand to check.
    IF v_target.user_is_active IS NOT TRUE
       OR (
           p_brand_id IS NOT NULL
           AND v_target.brand_is_active IS NOT TRUE
       ) THEN
        RAISE EXCEPTION
            'Assignments require an active user and, when supplied, an active brand'
            USING ERRCODE = '55000';
    END IF;

    -- Authorization already verified that this target shape
    -- matches the selected role.
    v_role_scope := CASE
        WHEN p_brand_id IS NULL THEN 'organization'
        ELSE 'brand'
    END;

    -- NULL-safe comparison is essential for organization assignments.
    IF EXISTS (
        SELECT 1
        FROM public.user_roles AS ur
        WHERE ur.user_id = p_target_user_id
          AND ur.organization_id = v_organization_id
          AND ur.role_id = p_role_id
          AND ur.brand_id IS NOT DISTINCT FROM p_brand_id
    ) THEN
        RETURN 'unchanged';
    END IF;

    INSERT INTO public.user_roles (
        user_id,
        organization_id,
        role_id,
        role_scope,
        brand_id
    )
    VALUES (
        p_target_user_id,
        v_organization_id,
        p_role_id,
        v_role_scope,
        p_brand_id
    );

    GET DIAGNOSTICS v_affected_rows = ROW_COUNT;

    IF v_affected_rows <> 1 THEN
        RAISE EXCEPTION 'Assignment change did not affect one row'
            USING ERRCODE = '42501';
    END IF;

    -- An audit failure rolls back the assignment insert.
    INSERT INTO identity_access.assignment_audit_log (
        actor_user_id,
        organization_id,
        target_user_id,
        assignment_scope,
        brand_id,
        location_id,
        action,
        old_role_id,
        new_role_id,
        request_id
    )
    VALUES (
        v_actor_id,
        v_organization_id,
        p_target_user_id,
        v_role_scope,
        p_brand_id,
        NULL,
        'grant',
        NULL,
        p_role_id,
        p_request_id
    );

    RETURN 'granted';
END;
$$;

REVOKE ALL
ON FUNCTION identity_access.grant_user_role(uuid, uuid, uuid, uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION identity_access.grant_user_role(uuid, uuid, uuid, uuid)
TO operations_hub_runtime;

-- Run controlled writes as the restricted, RLS-bound writer.
GRANT CREATE ON SCHEMA identity_access
TO operations_hub_assignment_writer;

GRANT operations_hub_assignment_writer TO postgres
WITH INHERIT FALSE, SET TRUE;

ALTER FUNCTION identity_access.grant_user_role(uuid, uuid, uuid, uuid)
OWNER TO operations_hub_assignment_writer;

REVOKE operations_hub_assignment_writer FROM postgres;

REVOKE CREATE ON SCHEMA identity_access
FROM operations_hub_assignment_writer;

CREATE FUNCTION identity_access.revoke_user_role(
    p_target_user_id uuid,
    p_role_id uuid,
    p_brand_id uuid,
    p_request_id uuid
)
RETURNS text
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_organization_id uuid;
    v_actor_id uuid;
    v_assignment record;
    v_affected_rows bigint;
BEGIN
    -- Organization assignments legitimately have a NULL brand.
    IF p_target_user_id IS NULL
       OR p_role_id IS NULL
       OR p_request_id IS NULL THEN
        RAISE EXCEPTION 'User, role, and request ID are required'
            USING ERRCODE = '22004';
    END IF;

    v_organization_id :=
        identity_access.lock_assignment_organization();

    v_actor_id := identity_access.current_active_user_id();

    -- Do not reveal assignment existence to unauthorized callers.
    IF NOT identity_access.can_manage_user_role(
        p_target_user_id,
        p_role_id,
        p_brand_id
    ) THEN
        RAISE EXCEPTION 'Assignment is unavailable or not authorized'
            USING ERRCODE = '42501';
    END IF;

    -- Read the exact assignment under the organization lock.
    SELECT ur.id, ur.role_scope
    INTO v_assignment
    FROM public.user_roles AS ur
    WHERE ur.user_id = p_target_user_id
      AND ur.organization_id = v_organization_id
      AND ur.role_id = p_role_id
      AND ur.brand_id IS NOT DISTINCT FROM p_brand_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Assignment is unavailable or not authorized'
            USING ERRCODE = '42501';
    END IF;

    -- No target-activity check: authorized cleanup may remove
    -- assignments from inactive users or inactive brands.
    DELETE FROM public.user_roles
    WHERE id = v_assignment.id
      AND organization_id = v_organization_id
      AND user_id = p_target_user_id
      AND role_id = p_role_id
      AND brand_id IS NOT DISTINCT FROM p_brand_id;

    GET DIAGNOSTICS v_affected_rows = ROW_COUNT;

    IF v_affected_rows <> 1 THEN
        RAISE EXCEPTION 'Assignment is unavailable or not authorized'
            USING ERRCODE = '42501';
    END IF;

    -- Record the removed role atomically with the deletion.
    INSERT INTO identity_access.assignment_audit_log (
        actor_user_id,
        organization_id,
        target_user_id,
        assignment_scope,
        brand_id,
        location_id,
        action,
        old_role_id,
        new_role_id,
        request_id
    )
    VALUES (
        v_actor_id,
        v_organization_id,
        p_target_user_id,
        v_assignment.role_scope,
        p_brand_id,
        NULL,
        'revoke',
        p_role_id,
        NULL,
        p_request_id
    );

    RETURN 'revoked';
END;
$$;

REVOKE ALL
ON FUNCTION identity_access.revoke_user_role(uuid, uuid, uuid, uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION identity_access.revoke_user_role(uuid, uuid, uuid, uuid)
TO operations_hub_runtime;

GRANT CREATE ON SCHEMA identity_access
TO operations_hub_assignment_writer;

GRANT operations_hub_assignment_writer TO postgres
WITH INHERIT FALSE, SET TRUE;

ALTER FUNCTION identity_access.revoke_user_role(uuid, uuid, uuid, uuid)
OWNER TO operations_hub_assignment_writer;

REVOKE operations_hub_assignment_writer FROM postgres;

REVOKE CREATE ON SCHEMA identity_access
FROM operations_hub_assignment_writer;