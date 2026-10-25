-- Create the runtime role if absent, then enforce its restricted attributes.
-- Existing memberships, object privileges, and ownership require separate checks.
--
-- PostgreSQL roles exist across the database cluster and may survive
-- a local database reset, so create this role only if it is absent.

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname = 'operations_hub_runtime'
    ) THEN
        CREATE ROLE operations_hub_runtime NOLOGIN;
    END IF;
END;
$$;

ALTER ROLE operations_hub_runtime
    NOLOGIN NOCREATEDB NOCREATEROLE
    NOINHERIT NOREPLICATION NOBYPASSRLS;

-- Keep authorization helpers in a separate, non-public schema.
CREATE SCHEMA IF NOT EXISTS identity_access;
REVOKE ALL ON SCHEMA identity_access
FROM PUBLIC, anon, authenticated;

-- Application data is accessed through the restricted Express backend.
-- PUBLIC means every PostgreSQL role, not the public schema.
REVOKE ALL PRIVILEGES ON TABLE
    public.organizations,
    public.users,
    public.brands,
    public.locations,
    public.roles,
    public.permissions,
    public.role_permissions,
    public.user_roles,
    public.user_locations
FROM PUBLIC, anon, authenticated;

-- Future application tables created by postgres must not automatically
-- grant access to the browser-facing Supabase roles.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    REVOKE ALL ON TABLES FROM PUBLIC, anon, authenticated;

-- Read the actor supplied by the trusted Express backend.
-- Missing, empty, or malformed identity returns NULL.
-- This function does not verify a JWT or check account activity.
CREATE FUNCTION identity_access.current_actor_id()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
    actor_text text;
BEGIN
    actor_text := pg_catalog.current_setting('app.user_id', true);

    IF actor_text IS NULL OR actor_text = '' THEN
        RETURN NULL;
    END IF;

    RETURN actor_text::uuid;

EXCEPTION
    WHEN invalid_text_representation THEN
        RETURN NULL;
END;
$$;

-- Functions normally receive PUBLIC execution privileges by default.
-- Limit this helper to the application runtime role.
REVOKE ALL ON FUNCTION identity_access.current_actor_id()
FROM PUBLIC, anon, authenticated;

GRANT USAGE ON SCHEMA identity_access
TO operations_hub_runtime;

GRANT EXECUTE ON FUNCTION identity_access.current_actor_id()
TO operations_hub_runtime;

-- Owns narrowly scoped authorization helpers.
-- Never grant this role to the runtime role or backend login.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname = 'operations_hub_auth_reader'
    ) THEN
        CREATE ROLE operations_hub_auth_reader
            NOLOGIN BYPASSRLS;
    END IF;
END;
$$;

ALTER ROLE operations_hub_auth_reader
    NOLOGIN NOCREATEDB NOCREATEROLE
    NOINHERIT NOREPLICATION BYPASSRLS;

-- BYPASSRLS does not itself grant access to tables.
GRANT USAGE ON SCHEMA public, identity_access
TO operations_hub_auth_reader;

GRANT SELECT (id, is_active) ON public.users
TO operations_hub_auth_reader;

-- The active-user helper calls our existing identity parser.
GRANT EXECUTE ON FUNCTION identity_access.current_actor_id()
TO operations_hub_auth_reader;

-- Return the actor only if their application profile is active.
-- Missing profiles and inactive accounts return NULL.
CREATE FUNCTION identity_access.current_active_user_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT u.id
    FROM public.users AS u
    WHERE u.id = identity_access.current_actor_id()
      AND u.is_active = true;
$$;

REVOKE ALL ON FUNCTION identity_access.current_active_user_id()
FROM PUBLIC, anon, authenticated;

-- Grant access while postgres still owns the function.
GRANT EXECUTE ON FUNCTION identity_access.current_active_user_id()
TO operations_hub_runtime;

-- The new owner needs CREATE on the containing schema.
GRANT CREATE ON SCHEMA identity_access
TO operations_hub_auth_reader;

-- Temporarily allow the migration role to transfer ownership.
-- Do not grant this membership to the application runtime role.
GRANT operations_hub_auth_reader TO postgres
WITH INHERIT FALSE, SET TRUE;

ALTER FUNCTION identity_access.current_active_user_id()
OWNER TO operations_hub_auth_reader;

-- Remove the temporary ownership-transfer privileges.
REVOKE operations_hub_auth_reader FROM postgres;

REVOKE CREATE ON SCHEMA identity_access
FROM operations_hub_auth_reader;