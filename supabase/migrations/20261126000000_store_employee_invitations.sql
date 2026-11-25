-- Private employee invitations. Only the backend runtime may call the entry points.
CREATE TABLE identity_access.store_invitations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    token uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations,
    location_id uuid NOT NULL REFERENCES public.locations,
    email text NOT NULL,
    invited_by uuid NOT NULL REFERENCES public.users,
    expires_at timestamptz NOT NULL DEFAULT (now() + interval '7 days'),
    accepted_by uuid REFERENCES public.users,
    cancelled_at timestamptz,
    CHECK (accepted_by IS NULL OR cancelled_at IS NULL)
);
CREATE UNIQUE INDEX store_invitations_pending ON identity_access.store_invitations(location_id,email)
    WHERE accepted_by IS NULL AND cancelled_at IS NULL;
REVOKE ALL ON identity_access.store_invitations FROM PUBLIC, anon, authenticated, operations_hub_runtime;

CREATE ROLE operations_hub_invitation_writer NOLOGIN;
GRANT USAGE, CREATE ON SCHEMA identity_access TO operations_hub_invitation_writer;
GRANT USAGE ON SCHEMA public TO operations_hub_invitation_writer;
GRANT SELECT, INSERT, UPDATE ON identity_access.store_invitations TO operations_hub_invitation_writer;
GRANT SELECT (id,email,organization_id,is_active), INSERT (id,email,organization_id,full_name)
    ON public.users TO operations_hub_invitation_writer;
GRANT SELECT (id,key) ON public.roles TO operations_hub_invitation_writer;
GRANT SELECT (user_id,location_id,role_id) ON public.user_locations TO operations_hub_invitation_writer;
CREATE POLICY users_invitation_select ON public.users FOR SELECT TO operations_hub_invitation_writer USING (true);
CREATE POLICY users_invitation_insert ON public.users FOR INSERT TO operations_hub_invitation_writer WITH CHECK (true);
CREATE POLICY roles_invitation_select ON public.roles FOR SELECT TO operations_hub_invitation_writer USING (key = 'employee');
CREATE POLICY user_locations_invitation_select ON public.user_locations FOR SELECT TO operations_hub_invitation_writer USING (true);

GRANT operations_hub_auth_reader, operations_hub_assignment_writer, operations_hub_invitation_writer
    TO postgres WITH INHERIT FALSE, SET TRUE;
SET ROLE operations_hub_auth_reader;
GRANT EXECUTE ON FUNCTION identity_access.current_location_ids_with(text),
    identity_access.current_user_organization_id() TO operations_hub_invitation_writer;
RESET ROLE;
SET ROLE operations_hub_assignment_writer;
GRANT EXECUTE ON FUNCTION identity_access.set_location_assignment(uuid,uuid,uuid,uuid),
    identity_access.revoke_location_assignment(uuid,uuid,uuid)
    TO operations_hub_invitation_writer;
RESET ROLE;
GRANT EXECUTE ON FUNCTION identity_access.lock_assignment_organization() TO operations_hub_invitation_writer;

SET ROLE operations_hub_invitation_writer;
CREATE FUNCTION identity_access.check_employee_invite_scope(loc uuid) RETURNS uuid
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE org uuid;
BEGIN
    org := identity_access.lock_assignment_organization();
    IF loc NOT IN (SELECT identity_access.current_location_ids_with('users.invite'))
       OR loc NOT IN (SELECT identity_access.current_location_ids_with('role_assignments.manage'))
       OR loc IS NULL THEN
        RAISE EXCEPTION 'Invitation not authorized' USING ERRCODE = '42501';
    END IF;
    RETURN org;
END;
$$;

CREATE FUNCTION identity_access.invite_store_employee(loc uuid, address text)
RETURNS identity_access.store_invitations LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    org uuid := identity_access.check_employee_invite_scope(loc);
    actor uuid := current_setting('app.user_id')::uuid;
    invitation identity_access.store_invitations;
BEGIN
    address := lower(trim(address));
    IF address IS NULL OR address = '' OR length(address) > 254 THEN
        RAISE EXCEPTION 'Invalid email' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT FROM public.users u WHERE u.organization_id = org AND lower(u.email) = address AND
        (NOT u.is_active OR u.id = actor OR EXISTS (
            SELECT FROM public.user_locations ul WHERE ul.user_id = u.id AND ul.location_id = loc))) THEN
        RAISE EXCEPTION 'Recipient unavailable' USING ERRCODE = '55000';
    END IF;
    -- A delivery retry keeps the same link. An expired link never becomes valid again.
    UPDATE identity_access.store_invitations SET cancelled_at = clock_timestamp()
      WHERE location_id = loc AND email = address AND accepted_by IS NULL AND cancelled_at IS NULL
        AND expires_at <= clock_timestamp();
    INSERT INTO identity_access.store_invitations(organization_id,location_id,email,invited_by)
      VALUES (org,loc,address,actor)
      ON CONFLICT (location_id,email) WHERE accepted_by IS NULL AND cancelled_at IS NULL
      DO UPDATE SET invited_by = EXCLUDED.invited_by RETURNING * INTO invitation;
    RETURN invitation;
END;
$$;

CREATE FUNCTION identity_access.pending_store_invitations(loc uuid)
RETURNS TABLE(id uuid, email text, expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    PERFORM identity_access.check_employee_invite_scope(loc);
    RETURN QUERY SELECT i.id, i.email, i.expires_at FROM identity_access.store_invitations i
      WHERE i.location_id = loc AND i.cancelled_at IS NULL AND i.accepted_by IS NULL
        AND i.expires_at > clock_timestamp() ORDER BY i.email;
END;
$$;

CREATE FUNCTION identity_access.cancel_store_invitation(loc uuid, invitation_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE org uuid := identity_access.check_employee_invite_scope(loc);
BEGIN
    UPDATE identity_access.store_invitations SET cancelled_at = coalesce(cancelled_at,clock_timestamp())
      WHERE id = invitation_id AND organization_id = org AND location_id = loc AND accepted_by IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'Invitation unavailable' USING ERRCODE = '55000'; END IF;
END;
$$;

CREATE FUNCTION identity_access.accept_store_invitation(invite_token uuid, verified_email text, display_name text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    recipient uuid := current_setting('app.user_id')::uuid;
    invitation identity_access.store_invitations;
    employee_role uuid;
BEGIN
    -- Discover the immutable organization, then lock and re-read under READ COMMITTED.
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'Invitation requires READ COMMITTED' USING ERRCODE = '25000';
    END IF;
    SELECT * INTO invitation FROM identity_access.store_invitations WHERE token = invite_token;
    IF NOT FOUND OR invitation.email IS DISTINCT FROM lower(verified_email) THEN
        RAISE EXCEPTION 'Invitation unavailable' USING ERRCODE = '42501';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('operations-hub:identity:' || invitation.organization_id::text,0));
    SELECT * INTO STRICT invitation FROM identity_access.store_invitations WHERE token = invite_token FOR UPDATE;
    IF invitation.accepted_by = recipient THEN RETURN invitation.location_id; END IF;
    IF invitation.cancelled_at IS NOT NULL OR invitation.accepted_by IS NOT NULL OR invitation.expires_at <= clock_timestamp() THEN
        RAISE EXCEPTION 'Invitation is closed' USING ERRCODE = '55000';
    END IF;
    IF display_name IS NULL OR length(trim(display_name)) NOT BETWEEN 1 AND 200 THEN
        RAISE EXCEPTION 'Invalid name' USING ERRCODE = '22023';
    END IF;
    -- Only this stored inviter can authorize the grant; no actor comes from the request body.
    PERFORM set_config('app.user_id', invitation.invited_by::text, true);
    IF identity_access.check_employee_invite_scope(invitation.location_id) <> invitation.organization_id THEN
        RAISE EXCEPTION 'Invitation not authorized' USING ERRCODE = '42501';
    END IF;
    INSERT INTO public.users(id,organization_id,email,full_name)
        VALUES (recipient,invitation.organization_id,invitation.email,trim(display_name))
        ON CONFLICT DO NOTHING;
    IF NOT EXISTS (SELECT FROM public.users u WHERE u.id = recipient AND u.is_active
                   AND u.organization_id = invitation.organization_id AND lower(u.email) = invitation.email) THEN
        RAISE EXCEPTION 'Recipient unavailable' USING ERRCODE = '42501';
    END IF;
    SELECT id INTO STRICT employee_role FROM public.roles WHERE key = 'employee';
    IF EXISTS (SELECT FROM public.user_locations WHERE user_id = recipient AND location_id = invitation.location_id
               AND role_id <> employee_role) THEN
        RAISE EXCEPTION 'Existing role cannot be replaced by invitation' USING ERRCODE = '55000';
    END IF;
    PERFORM identity_access.set_location_assignment(recipient,invitation.location_id,employee_role,invitation.id);
    PERFORM set_config('app.user_id', recipient::text, true);
    UPDATE identity_access.store_invitations SET accepted_by = recipient WHERE id = invitation.id;
    RETURN invitation.location_id;
END;
$$;

CREATE FUNCTION identity_access.remove_invited_member(recipient uuid, loc uuid, request_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    -- Existing writer locks the organization, checks the stored role and records the revoke.
    PERFORM identity_access.revoke_location_assignment(recipient,loc,request_id);
    UPDATE identity_access.store_invitations SET cancelled_at = clock_timestamp()
      WHERE location_id = loc AND email = (SELECT lower(email) FROM public.users WHERE id = recipient)
        AND accepted_by IS NULL AND cancelled_at IS NULL;
END;
$$;

REVOKE ALL ON FUNCTION identity_access.check_employee_invite_scope(uuid),
    identity_access.invite_store_employee(uuid,text), identity_access.pending_store_invitations(uuid),
    identity_access.cancel_store_invitation(uuid,uuid),
    identity_access.accept_store_invitation(uuid,text,text), identity_access.remove_invited_member(uuid,uuid,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION identity_access.invite_store_employee(uuid,text), identity_access.pending_store_invitations(uuid),
    identity_access.cancel_store_invitation(uuid,uuid), identity_access.accept_store_invitation(uuid,text,text), identity_access.remove_invited_member(uuid,uuid,uuid)
    TO operations_hub_runtime;
RESET ROLE;
REVOKE CREATE ON SCHEMA identity_access FROM operations_hub_invitation_writer;
REVOKE operations_hub_auth_reader, operations_hub_assignment_writer, operations_hub_invitation_writer FROM postgres;
