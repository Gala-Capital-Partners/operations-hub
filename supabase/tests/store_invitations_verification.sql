BEGIN;
GRANT operations_hub_runtime TO postgres WITH INHERIT FALSE, SET TRUE;
DO $$
DECLARE
    org uuid := gen_random_uuid();
    foreign_org uuid := gen_random_uuid();
    foreign_person uuid := gen_random_uuid();
    foreign_email text := foreign_person::text || '@example.invalid';
    brand uuid := gen_random_uuid();
    store uuid := gen_random_uuid();
    other_store uuid := gen_random_uuid();
    manager uuid := gen_random_uuid();
    person uuid := gen_random_uuid();
    email text := person::text || '@example.invalid';
    invite identity_access.store_invitations;
    retried identity_access.store_invitations;
BEGIN
    INSERT INTO public.organizations(id,name) VALUES(org,'Invitation checks'),(foreign_org,'Other organization');
    INSERT INTO public.brands(id,organization_id,name,slug) VALUES(brand,org,'Test',brand::text);
    INSERT INTO public.locations(id,brand_id,name,timezone) VALUES(store,brand,'A','UTC'),(other_store,brand,'B','UTC');
    INSERT INTO auth.users(id) VALUES(manager),(person),(foreign_person);
    INSERT INTO public.users(id,organization_id,email,full_name) VALUES(foreign_person,foreign_org,foreign_email,'Other employee');
    INSERT INTO public.users(id,organization_id,email,full_name) VALUES(manager,org,manager::text || '@example.invalid','Manager');
    INSERT INTO public.user_locations(user_id,organization_id,brand_id,location_id,role_id)
      SELECT manager,org,brand,store,id FROM public.roles WHERE key='location_manager';
    SET LOCAL ROLE operations_hub_runtime;
    PERFORM set_config('app.user_id',manager::text,true);
    BEGIN
        PERFORM identity_access.invite_store_employee(other_store,email);
        RAISE EXCEPTION 'Manager invited outside assigned store';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    invite := identity_access.invite_store_employee(store,foreign_email);
    PERFORM set_config('app.user_id',foreign_person::text,true);
    BEGIN
        PERFORM identity_access.accept_store_invitation(invite.token,foreign_email,'Other employee');
        RAISE EXCEPTION 'Cross-organization invitation granted access';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    RESET ROLE;
    UPDATE public.users SET is_active = false WHERE id = foreign_person;
    SET LOCAL ROLE operations_hub_runtime;
    PERFORM set_config('app.user_id',manager::text,true);
    PERFORM identity_access.invite_store_employee(store,foreign_email);
    invite := identity_access.invite_store_employee(store,email);
    retried := identity_access.invite_store_employee(store,email);
    IF invite.token <> retried.token THEN RAISE EXCEPTION 'Resend invalidated invitation'; END IF;
    IF (SELECT count(*) FROM identity_access.pending_store_invitations(store) WHERE id = invite.id) <> 1 THEN
        RAISE EXCEPTION 'Missing pending invitation';
    END IF;
    PERFORM identity_access.cancel_store_invitation(store,invite.id);
    PERFORM set_config('app.user_id',person::text,true);
    BEGIN
        PERFORM identity_access.accept_store_invitation(invite.token,email,'Employee');
        RAISE EXCEPTION 'Cancelled invitation accepted';
    EXCEPTION WHEN SQLSTATE '55000' THEN NULL;
    END;

    PERFORM set_config('app.user_id',manager::text,true);
    invite := identity_access.invite_store_employee(store,email);
    RESET ROLE;
    UPDATE identity_access.store_invitations SET expires_at = now() WHERE id = invite.id;
    SET LOCAL ROLE operations_hub_runtime;
    PERFORM set_config('app.user_id',person::text,true);
    BEGIN
        PERFORM identity_access.accept_store_invitation(invite.token,email,'Employee');
        RAISE EXCEPTION 'Expired invitation accepted';
    EXCEPTION WHEN SQLSTATE '55000' THEN NULL;
    END;
    PERFORM set_config('app.user_id',manager::text,true);
    retried := identity_access.invite_store_employee(store,email);
    IF invite.token = retried.token THEN RAISE EXCEPTION 'Expired link reused'; END IF;
    PERFORM set_config('app.user_id',person::text,true);
    BEGIN
        PERFORM identity_access.accept_store_invitation(retried.token,'wrong@example.invalid','Employee');
        RAISE EXCEPTION 'Wrong recipient accepted';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    RESET ROLE;
    UPDATE public.users SET is_active = false WHERE id = manager;
    SET LOCAL ROLE operations_hub_runtime;
    BEGIN
        PERFORM identity_access.accept_store_invitation(retried.token,email,'Employee');
        RAISE EXCEPTION 'Inactive inviter granted access';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    RESET ROLE;
    IF EXISTS (SELECT FROM public.users WHERE id = person) THEN RAISE EXCEPTION 'Partial profile created'; END IF;
    UPDATE public.users SET is_active = true WHERE id = manager;
    SET LOCAL ROLE operations_hub_runtime;
    PERFORM identity_access.accept_store_invitation(retried.token,email,'Employee');
    PERFORM identity_access.accept_store_invitation(retried.token,email,'Employee');
    IF store NOT IN (SELECT identity_access.current_location_ids_with('task_instances.read')) THEN
        RAISE EXCEPTION 'Accepted employee cannot see store';
    END IF;
    BEGIN
        PERFORM identity_access.invite_store_employee(store,'other@example.invalid');
        RAISE EXCEPTION 'Employee issued an invitation';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    RESET ROLE;
    INSERT INTO public.user_locations(user_id,organization_id,brand_id,location_id,role_id)
      SELECT person,org,brand,other_store,id FROM public.roles WHERE key='employee';
    SET LOCAL ROLE operations_hub_runtime;
    PERFORM set_config('app.user_id',manager::text,true);
    PERFORM identity_access.remove_invited_member(person,store,gen_random_uuid());
    PERFORM set_config('app.user_id',person::text,true);
    PERFORM identity_access.accept_store_invitation(retried.token,email,'Employee');
    IF store IN (SELECT identity_access.current_location_ids_with('task_instances.read'))
        OR other_store NOT IN (SELECT identity_access.current_location_ids_with('task_instances.read')) THEN
        RAISE EXCEPTION 'Removal did not isolate the store or accepted link restored access';
    END IF;
    RESET ROLE;
END;
$$;
ROLLBACK;
