-- Controlled writes for location-scoped role assignments.
--
-- Runtime keeps SELECT-only access to assignment tables.
-- Changes must go through explicitly authorized database functions.
--
-- Rules:
-- 1. Require an active caller and role_assignments.manage.
-- 2. Enforce the approved actor-role / target-role matrix.
-- 3. Reject changes to the caller's own assignments.
-- 4. Validate both existing and proposed roles during replacement.
-- 5. Keep user_id and location_id fixed during replacement.
-- 6. Record actual changes atomically in an audit log.
--
-- Organization and brand assignment writes are handled separately.

CREATE FUNCTION identity_access.can_manage_location_assignment(
    target_user_id uuid,
    target_location_id uuid,
    target_role_id uuid
) RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.users AS target_user
        JOIN public.locations AS target_location
          ON target_location.id = target_location_id
        JOIN public.brands AS target_brand
          ON target_brand.id = target_location.brand_id
        JOIN public.roles AS target_role
          ON target_role.id = target_role_id
        WHERE target_user.id = target_user_id

          -- Caller must be active and cannot modify their own assignments.
          AND identity_access.current_active_user_id() IS NOT NULL
          AND target_user.id <>
              identity_access.current_active_user_id()

          -- Target user and location must belong to the same organization.
          AND target_user.organization_id =
              target_brand.organization_id

          -- This operation handles only the approved location roles.
          AND target_role.scope = 'location'
          AND target_role.key IN ('employee', 'location_manager')

          AND EXISTS (
              SELECT 1
              FROM identity_access.current_user_permissions() AS p
              WHERE p.permission_key = 'role_assignments.manage'
                AND p.organization_id = target_brand.organization_id
                AND (
                    (
                        p.role_key = 'org_admin'
                        AND p.role_scope = 'organization'
                    )
                    OR (
                        p.role_key = 'brand_admin'
                        AND p.role_scope = 'brand'
                        AND p.brand_id = target_brand.id
                    )
                    OR (
                        p.role_key = 'location_manager'
                        AND p.role_scope = 'location'
                        AND p.brand_id = target_brand.id
                        AND p.location_id = target_location.id
                        AND target_role.key = 'employee'
                    )
                )
          )
    );
$$;

-- Internal authorization helper. It accepts target IDs and is intended
-- for controlled write functions, not direct application calls.
REVOKE ALL
ON FUNCTION identity_access.can_manage_location_assignment(uuid, uuid, uuid)
FROM PUBLIC, anon, authenticated, operations_hub_runtime;

-- The existing reader role already has the SELECT privileges needed
-- to evaluate the authorization query.
GRANT CREATE ON SCHEMA identity_access
TO operations_hub_auth_reader;

GRANT operations_hub_auth_reader TO postgres
WITH INHERIT FALSE, SET TRUE;

ALTER FUNCTION identity_access.can_manage_location_assignment(uuid, uuid, uuid)
OWNER TO operations_hub_auth_reader;

REVOKE operations_hub_auth_reader FROM postgres;

REVOKE CREATE ON SCHEMA identity_access
FROM operations_hub_auth_reader;

-- Owns controlled assignment-write functions.
-- Cannot log in directly or manage database roles.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname = 'operations_hub_assignment_writer'
    ) THEN
        CREATE ROLE operations_hub_assignment_writer NOLOGIN;
    END IF;
END;
$$;

ALTER ROLE operations_hub_assignment_writer
    NOLOGIN
    NOCREATEDB
    NOCREATEROLE
    NOINHERIT
    NOREPLICATION
    NOBYPASSRLS;

-- Access to object names does not grant access to table contents.
GRANT USAGE ON SCHEMA public, identity_access
TO operations_hub_assignment_writer;

-- These helpers are already owned by auth_reader. The migration role must
-- temporarily act as that owner to grant execution; postgres is not a superuser.
GRANT operations_hub_auth_reader TO postgres WITH INHERIT FALSE, SET TRUE;
SET ROLE operations_hub_auth_reader;

GRANT EXECUTE ON FUNCTION identity_access.current_active_user_id(),
    identity_access.can_manage_location_assignment(uuid, uuid, uuid),
    identity_access.current_user_organization_id()
TO operations_hub_assignment_writer;

RESET ROLE;
REVOKE operations_hub_auth_reader FROM postgres;

-- Internal audit history. No direct runtime access.
-- This first version records location-assignment changes only.
CREATE TABLE identity_access.assignment_audit_log (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    actor_user_id uuid NOT NULL,
    organization_id uuid NOT NULL,
    target_user_id uuid NOT NULL,
    location_id uuid NOT NULL,

    action text NOT NULL
        CHECK (action IN ('grant', 'replace', 'revoke')),

    old_role_id uuid,
    new_role_id uuid,

    -- Express will supply a request ID for tracing.
    -- It is correlation metadata, not proof of authorization.
    request_id uuid NOT NULL,

    occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT assignment_audit_change_check CHECK (
        (
            action = 'grant'
            AND old_role_id IS NULL
            AND new_role_id IS NOT NULL
        )
        OR (
            action = 'replace'
            AND old_role_id IS NOT NULL
            AND new_role_id IS NOT NULL
            AND old_role_id <> new_role_id
        )
        OR (
            action = 'revoke'
            AND old_role_id IS NOT NULL
            AND new_role_id IS NULL
        )
    )
);

CREATE INDEX assignment_audit_org_time_idx
ON identity_access.assignment_audit_log
    (organization_id, occurred_at);

CREATE INDEX assignment_audit_request_idx
ON identity_access.assignment_audit_log (request_id);

ALTER TABLE identity_access.assignment_audit_log
ENABLE ROW LEVEL SECURITY;

-- Only controlled write functions may append audit records.
REVOKE ALL
ON identity_access.assignment_audit_log
FROM PUBLIC, anon, authenticated, operations_hub_runtime;

GRANT INSERT
ON identity_access.assignment_audit_log
TO operations_hub_assignment_writer;

CREATE POLICY assignment_audit_insert_writer
ON identity_access.assignment_audit_log
FOR INSERT
TO operations_hub_assignment_writer
WITH CHECK (
    actor_user_id =
        (SELECT identity_access.current_active_user_id())
);

-- The writer can inspect assignments within the caller's organization.
-- This lets controlled functions distinguish an existing forbidden
-- assignment from an assignment that does not exist.

GRANT SELECT, DELETE
ON public.user_locations
TO operations_hub_assignment_writer;

GRANT INSERT (
    user_id,
    location_id,
    organization_id,
    brand_id,
    role_id,
    role_scope
)
ON public.user_locations
TO operations_hub_assignment_writer;

-- A replacement changes only the role.
-- The existing timestamp trigger maintains updated_at.
GRANT UPDATE (role_id)
ON public.user_locations
TO operations_hub_assignment_writer;


CREATE POLICY user_locations_writer_select
ON public.user_locations
FOR SELECT
TO operations_hub_assignment_writer
USING (
    organization_id = (
        SELECT identity_access.current_user_organization_id()
    )
);


CREATE POLICY user_locations_writer_insert
ON public.user_locations
FOR INSERT
TO operations_hub_assignment_writer
WITH CHECK (
    identity_access.can_manage_location_assignment(
        user_id,
        location_id,
        role_id
    )
);


CREATE POLICY user_locations_writer_update
ON public.user_locations
FOR UPDATE
TO operations_hub_assignment_writer
USING (
    -- Check authority over the existing role.
    identity_access.can_manage_location_assignment(
        user_id,
        location_id,
        role_id
    )
)
WITH CHECK (
    -- Check authority over the proposed replacement role.
    identity_access.can_manage_location_assignment(
        user_id,
        location_id,
        role_id
    )
);


CREATE POLICY user_locations_writer_delete
ON public.user_locations
FOR DELETE
TO operations_hub_assignment_writer
USING (
    identity_access.can_manage_location_assignment(
        user_id,
        location_id,
        role_id
    )
);

-- Resolve target details without requiring an existing assignment.
-- Returns at most one row, limited to the active caller's organization.
-- This is a lookup, not authorization to change the assignment.
CREATE FUNCTION identity_access.location_assignment_target(
    target_user_id uuid,
    target_location_id uuid
)
RETURNS TABLE (
    organization_id uuid,
    brand_id uuid,
    user_is_active boolean,
    brand_is_active boolean,
    location_is_active boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT
        u.organization_id,
        b.id,
        u.is_active,
        b.is_active,
        l.is_active
    FROM public.users AS u
    JOIN public.locations AS l
      ON l.id = target_location_id
    JOIN public.brands AS b
      ON b.id = l.brand_id
     AND b.organization_id = u.organization_id
    WHERE u.id = target_user_id
      AND u.organization_id = (
          SELECT identity_access.current_user_organization_id()
      );
$$;

REVOKE ALL
ON FUNCTION identity_access.location_assignment_target(uuid, uuid)
FROM PUBLIC, anon, authenticated, operations_hub_runtime;

GRANT EXECUTE
ON FUNCTION identity_access.location_assignment_target(uuid, uuid)
TO operations_hub_assignment_writer;

-- The reader already has access to the columns used above.
GRANT CREATE ON SCHEMA identity_access
TO operations_hub_auth_reader;

GRANT operations_hub_auth_reader TO postgres
WITH INHERIT FALSE, SET TRUE;

ALTER FUNCTION identity_access.location_assignment_target(uuid, uuid)
OWNER TO operations_hub_auth_reader;

REVOKE operations_hub_auth_reader FROM postgres;

REVOKE CREATE ON SCHEMA identity_access
FROM operations_hub_auth_reader;

-- Serialize cooperating identity changes within one organization.
-- Acquire this before resolving targets and checking write authority.
CREATE FUNCTION identity_access.lock_assignment_organization()
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
    caller_organization_id uuid;
BEGIN
    -- Subsequent statements must see changes committed while we waited.
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION
            'Assignment writes require READ COMMITTED isolation'
            USING ERRCODE = '25000';
    END IF;

    caller_organization_id :=
        identity_access.current_user_organization_id();

    IF caller_organization_id IS NULL THEN
        RAISE EXCEPTION 'An active application user is required'
            USING ERRCODE = '42501';
    END IF;

    -- Same organization produces the same lock key.
    PERFORM pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(
            'operations-hub:identity:' ||
            caller_organization_id::text,
            0
        )
    );

    -- The caller may have been deactivated while waiting.
    IF identity_access.current_user_organization_id()
       IS DISTINCT FROM caller_organization_id THEN
        RAISE EXCEPTION 'Caller identity changed while waiting'
            USING ERRCODE = '42501';
    END IF;

    RETURN caller_organization_id;
END;
$$;

REVOKE ALL
ON FUNCTION identity_access.lock_assignment_organization()
FROM PUBLIC, anon, authenticated, operations_hub_runtime;

GRANT EXECUTE
ON FUNCTION identity_access.lock_assignment_organization()
TO operations_hub_assignment_writer;

CREATE FUNCTION identity_access.set_location_assignment(
    p_target_user_id uuid,
    p_location_id uuid,
    p_role_id uuid,
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
    v_old_role_id uuid;
    v_has_assignment boolean;
    v_action text;
    v_affected_rows bigint;
BEGIN
    -- Reject incomplete requests before doing any work.
    IF p_target_user_id IS NULL
       OR p_location_id IS NULL
       OR p_role_id IS NULL
       OR p_request_id IS NULL THEN
        RAISE EXCEPTION 'All arguments are required'
            USING ERRCODE = '22004';
    END IF;

    -- All cooperating identity writers acquire this lock first.
    v_organization_id :=
        identity_access.lock_assignment_organization();

    v_actor_id := identity_access.current_active_user_id();

    -- Resolve trusted target details after acquiring the lock.
    SELECT *
    INTO v_target
    FROM identity_access.location_assignment_target(
        p_target_user_id,
        p_location_id
    );

    IF NOT FOUND THEN
        -- Match the authorization failure below so callers cannot infer
        -- whether a hidden user/location pair exists from the message.
        RAISE EXCEPTION 'Assignment change is not authorized'
            USING ERRCODE = '42501';
    END IF;

    -- Check the proposed role before exposing target activity details.
    IF NOT identity_access.can_manage_location_assignment(
        p_target_user_id,
        p_location_id,
        p_role_id
    ) THEN
        RAISE EXCEPTION 'Assignment change is not authorized'
            USING ERRCODE = '42501';
    END IF;

    -- Grants and replacements require active targets.
    IF NOT v_target.user_is_active
       OR NOT v_target.brand_is_active
       OR NOT v_target.location_is_active THEN
        RAISE EXCEPTION
            'Assignments require an active user, brand, and location'
            USING ERRCODE = '55000';
    END IF;

    -- Read the existing assignment under the organization lock.
    -- Writer SELECT policy lets us detect an existing role even when
    -- the caller is not permitted to change that role.
    SELECT ul.role_id
    INTO v_old_role_id
    FROM public.user_locations AS ul
    WHERE ul.user_id = p_target_user_id
      AND ul.location_id = p_location_id;

    v_has_assignment := FOUND;

    IF v_has_assignment THEN
        -- Replacement requires authority over the OLD role as well.
        IF NOT identity_access.can_manage_location_assignment(
            p_target_user_id,
            p_location_id,
            v_old_role_id
        ) THEN
            RAISE EXCEPTION 'Existing assignment cannot be changed'
                USING ERRCODE = '42501';
        END IF;

        IF v_old_role_id = p_role_id THEN
            RETURN 'unchanged';
        END IF;

        UPDATE public.user_locations
        SET role_id = p_role_id
        WHERE user_id = p_target_user_id
          AND location_id = p_location_id
          AND role_id = v_old_role_id;

        v_action := 'replace';
    ELSE
        INSERT INTO public.user_locations (
            user_id,
            location_id,
            organization_id,
            brand_id,
            role_id,
            role_scope
        )
        VALUES (
            p_target_user_id,
            p_location_id,
            v_organization_id,
            v_target.brand_id,
            p_role_id,
            'location'
        );

        v_action := 'grant';
    END IF;

    -- Do not report success if RLS filtered out an intended update.
    GET DIAGNOSTICS v_affected_rows = ROW_COUNT;

    IF v_affected_rows <> 1 THEN
        RAISE EXCEPTION 'Assignment change did not affect one row'
            USING ERRCODE = '42501';
    END IF;

    -- Same transaction as the assignment change:
    -- if this insert fails, the assignment change must not persist.
    INSERT INTO identity_access.assignment_audit_log (
        actor_user_id,
        organization_id,
        target_user_id,
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
        p_location_id,
        v_action,
        v_old_role_id,
        p_role_id,
        p_request_id
    );

    RETURN CASE v_action
        WHEN 'grant' THEN 'granted'
        ELSE 'replaced'
    END;
END;
$$;

REVOKE ALL
ON FUNCTION identity_access.set_location_assignment(
    uuid, uuid, uuid, uuid
)
FROM PUBLIC, anon, authenticated;

-- The backend may execute this controlled entry point.
GRANT EXECUTE
ON FUNCTION identity_access.set_location_assignment(
    uuid, uuid, uuid, uuid
)
TO operations_hub_runtime;

GRANT CREATE ON SCHEMA identity_access
TO operations_hub_assignment_writer;

GRANT operations_hub_assignment_writer TO postgres
WITH INHERIT FALSE, SET TRUE;

ALTER FUNCTION identity_access.set_location_assignment(
    uuid, uuid, uuid, uuid
)
OWNER TO operations_hub_assignment_writer;

REVOKE operations_hub_assignment_writer FROM postgres;

REVOKE CREATE ON SCHEMA identity_access
FROM operations_hub_assignment_writer;

CREATE FUNCTION identity_access.revoke_location_assignment(
    p_target_user_id uuid,
    p_location_id uuid,
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
    v_old_role_id uuid;
    v_affected_rows bigint;
BEGIN
    IF p_target_user_id IS NULL
       OR p_location_id IS NULL
       OR p_request_id IS NULL THEN
        RAISE EXCEPTION 'All arguments are required'
            USING ERRCODE = '22004';
    END IF;

    -- Use the same lock as grants and replacements.
    v_organization_id :=
        identity_access.lock_assignment_organization();

    v_actor_id := identity_access.current_active_user_id();

    -- Writer RLS limits this lookup to the caller's organization.
    SELECT ul.role_id
    INTO v_old_role_id
    FROM public.user_locations AS ul
    WHERE ul.user_id = p_target_user_id
      AND ul.location_id = p_location_id;

    IF NOT FOUND THEN
        -- Avoid distinguishing missing assignments from inaccessible ones.
        RAISE EXCEPTION 'Assignment is unavailable or not authorized'
            USING ERRCODE = '42501';
    END IF;

    -- Check the actual stored role, not a role supplied by the caller.
    -- This also rejects changes to the caller's own assignments.
    IF NOT identity_access.can_manage_location_assignment(
        p_target_user_id,
        p_location_id,
        v_old_role_id
    ) THEN
        RAISE EXCEPTION 'Assignment is unavailable or not authorized'
            USING ERRCODE = '42501';
    END IF;

    -- Unlike granting, revoking may remove an obsolete assignment
    -- whose target user or location is inactive.
    -- The caller must still have current authority over that target.
    DELETE FROM public.user_locations
    WHERE user_id = p_target_user_id
      AND location_id = p_location_id
      AND role_id = v_old_role_id;

    GET DIAGNOSTICS v_affected_rows = ROW_COUNT;

    IF v_affected_rows <> 1 THEN
        RAISE EXCEPTION 'Assignment removal did not affect one row'
            USING ERRCODE = '42501';
    END IF;

    INSERT INTO identity_access.assignment_audit_log (
        actor_user_id,
        organization_id,
        target_user_id,
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
        p_location_id,
        'revoke',
        v_old_role_id,
        NULL,
        p_request_id
    );

    RETURN 'revoked';
END;
$$;

REVOKE ALL
ON FUNCTION identity_access.revoke_location_assignment(uuid, uuid, uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION identity_access.revoke_location_assignment(uuid, uuid, uuid)
TO operations_hub_runtime;

GRANT CREATE ON SCHEMA identity_access
TO operations_hub_assignment_writer;

GRANT operations_hub_assignment_writer TO postgres
WITH INHERIT FALSE, SET TRUE;

ALTER FUNCTION identity_access.revoke_location_assignment(uuid, uuid, uuid)
OWNER TO operations_hub_assignment_writer;

REVOKE operations_hub_assignment_writer FROM postgres;

REVOKE CREATE ON SCHEMA identity_access
FROM operations_hub_assignment_writer;
