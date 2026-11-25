-- Manager task summary (GET /api/task-instances/summary).
-- Runs the same queries as summaryQuery and reportAccessQuery in
-- server/src/controller/task-instances.controller.ts; keep them in sync.
-- Synthetic fixtures; all data and temporary role membership roll back.
BEGIN;
GRANT operations_hub_runtime TO postgres WITH INHERIT FALSE, SET TRUE;

-- Returns "brand/location=total/completed" rows, in API order, joined by "; ".
CREATE FUNCTION pg_temp.summary_for(actor uuid, target_day date)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE actual text;
BEGIN
    PERFORM set_config('app.user_id', coalesce(actor::text, ''), true);
    SET LOCAL ROLE operations_hub_runtime;
    SELECT coalesce(string_agg(s.brand_name || '/' || s.location_name || '=' || s.total || '/' || s.completed,
            '; ' ORDER BY s.brand_name, s.location_name, s.location_id), '')
        INTO actual
    FROM (
        SELECT
            l.id AS location_id,
            l.name AS location_name,
            l.store_number,
            l.timezone,
            b.id AS brand_id,
            b.name AS brand_name,
            count(t.id)::int AS total,
            count(t.completed_at)::int AS completed
        FROM identity_access.current_location_ids_with(
            'reports.read'
        ) AS permitted(location_id)
        JOIN public.locations AS l
            ON l.id = permitted.location_id
        JOIN public.brands AS b
            ON b.id = l.brand_id
        LEFT JOIN public.task_instances AS t
            ON t.location_id = l.id
            AND t.scheduled_day = target_day
            AND t.cancelled_at IS NULL
        GROUP BY l.id, l.name, l.store_number, l.timezone, b.id, b.name
        ORDER BY b.name, l.name, l.id
    ) AS s;
    RESET ROLE;
    RETURN actual;
END;
$$;

-- reportAccessQuery: false means the API answers 403.
CREATE FUNCTION pg_temp.can_report(actor uuid)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE allowed boolean;
BEGIN
    PERFORM set_config('app.user_id', coalesce(actor::text, ''), true);
    SET LOCAL ROLE operations_hub_runtime;
    SELECT EXISTS (
        SELECT 1
        FROM identity_access.current_user_permissions() AS p
        WHERE p.permission_key = 'reports.read'
    ) INTO allowed;
    RESET ROLE;
    RETURN allowed;
END;
$$;

CREATE FUNCTION pg_temp.assert_can_report(actor uuid, expected boolean, label text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF pg_temp.can_report(actor) IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'reports.read access for % should be %', label, expected;
    END IF;
END;
$$;

CREATE FUNCTION pg_temp.assert_summary(actor uuid, target_day date, expected text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE actual text := pg_temp.summary_for(actor, target_day);
BEGIN
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'Unexpected summary for actor % on %: "%", expected "%"',
            actor, target_day, actual, expected;
    END IF;
END;
$$;

DO $$
DECLARE
    org_a uuid := gen_random_uuid(); org_b uuid := gen_random_uuid();
    brand_a uuid := gen_random_uuid(); brand_b uuid := gen_random_uuid();
    brand_foreign uuid := gen_random_uuid();
    a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid();
    b1 uuid := gen_random_uuid(); f1 uuid := gen_random_uuid();
    employee uuid := gen_random_uuid(); manager uuid := gen_random_uuid();
    brand_admin uuid := gen_random_uuid(); org_admin uuid := gen_random_uuid();
    outsider uuid := gen_random_uuid(); no_assignment uuid := gen_random_uuid();
    mixed uuid := gen_random_uuid();
    def uuid; item record;
BEGIN
    INSERT INTO public.organizations(id,name) VALUES(org_a,'Summary A'),(org_b,'Summary B');
    INSERT INTO public.brands(id,organization_id,name,slug) VALUES
        (brand_a,org_a,'Alpha',brand_a::text),(brand_b,org_a,'Bravo',brand_b::text),
        (brand_foreign,org_b,'Foreign',brand_foreign::text);
    INSERT INTO public.locations(id,brand_id,name,timezone) VALUES
        (a1,brand_a,'A1 Assigned','UTC'),(a2,brand_a,'A2 Empty','UTC'),
        (b1,brand_b,'B1 Other brand','UTC'),(f1,brand_foreign,'F1 Foreign','UTC');
    INSERT INTO auth.users(id) SELECT unnest(ARRAY[employee,manager,brand_admin,org_admin,outsider,no_assignment,mixed]);
    INSERT INTO public.users(id,organization_id,email,full_name)
        SELECT id, CASE WHEN id=outsider THEN org_b ELSE org_a END,
            id::text || '@example.invalid','Summary reader'
        FROM unnest(ARRAY[employee,manager,brand_admin,org_admin,outsider,no_assignment,mixed]) AS u(id);
    -- mixed manages A1 and is an employee at B1.
    INSERT INTO public.user_locations(user_id,organization_id,brand_id,location_id,role_id)
        SELECT v.actor,org_a,v.brand,v.loc,r.id
        FROM (VALUES(employee,brand_a,a1,'employee'),(manager,brand_a,a1,'location_manager'),
                    (mixed,brand_a,a1,'location_manager'),(mixed,brand_b,b1,'employee')
             ) v(actor,brand,loc,role_key)
        JOIN public.roles r ON r.key=v.role_key;
    INSERT INTO public.user_roles(user_id,organization_id,brand_id,role_id,role_scope)
        SELECT actor,org,brand,r.id,r.scope
        FROM (VALUES (org_admin,org_a,NULL::uuid,'org_admin'),
                     (brand_admin,org_a,brand_a,'brand_admin'),
                     (outsider,org_b,NULL::uuid,'org_admin')) v(actor,org,brand,role_key)
        JOIN public.roles r ON r.key=v.role_key;

    -- A1: two tasks on Nov 19 (one done) and one on Nov 20. A2: none.
    -- B1: one open task on Nov 19. F1 (other organization): one done task.
    FOR item IN SELECT * FROM (VALUES
            (a1,brand_a,'2026-11-19'::date,employee),
            (a1,brand_a,'2026-11-19'::date,NULL::uuid),
            (a1,brand_a,'2026-11-20'::date,NULL::uuid),
            (b1,brand_b,'2026-11-19'::date,NULL::uuid),
            (f1,brand_foreign,'2026-11-19'::date,outsider)
        ) v(loc,brand,day,done_by)
    LOOP
        INSERT INTO public.task_definitions(brand_id,location_id,created_by,name,description,category,start_date)
            VALUES(item.brand,item.loc,coalesce(item.done_by,employee),'Summary test','','Opening','2026-11-01')
            RETURNING id INTO def;
        INSERT INTO public.task_instances(brand_id,location_id,definition_id,scheduled_day,name_snapshot,
                description_snapshot,category_snapshot,timezone_snapshot,scheduled_at,is_all_day_snapshot,
                completed_at,completed_by)
            VALUES(item.brand,item.loc,def,item.day,'Summary test','','Opening','UTC',
                item.day::timestamp AT TIME ZONE 'UTC',true,
                CASE WHEN item.done_by IS NULL THEN NULL ELSE now() END,item.done_by);
    END LOOP;

    -- Employees have task_instances.read but not reports.read: no report (API 403).
    PERFORM pg_temp.assert_can_report(employee,false,'employee');
    PERFORM pg_temp.assert_summary(employee,'2026-11-19','');
    -- Location managers see the store they manage.
    PERFORM pg_temp.assert_can_report(manager,true,'manager');
    PERFORM pg_temp.assert_summary(manager,'2026-11-19','Alpha/A1 Assigned=2/1');
    -- Manager at A1 and employee at B1: only A1, although B1 tasks are readable.
    PERFORM pg_temp.assert_can_report(mixed,true,'mixed manager/employee');
    PERFORM pg_temp.assert_summary(mixed,'2026-11-19','Alpha/A1 Assigned=2/1');
    -- Brand admin sees every store in the brand, including one with no tasks.
    PERFORM pg_temp.assert_can_report(brand_admin,true,'brand admin');
    PERFORM pg_temp.assert_summary(brand_admin,'2026-11-19','Alpha/A1 Assigned=2/1; Alpha/A2 Empty=0/0');
    -- Organization admin sees all brands in the organization, never another organization.
    PERFORM pg_temp.assert_summary(org_admin,'2026-11-19',
        'Alpha/A1 Assigned=2/1; Alpha/A2 Empty=0/0; Bravo/B1 Other brand=1/0');
    PERFORM pg_temp.assert_summary(outsider,'2026-11-19','Foreign/F1 Foreign=1/1');
    -- The date filter counts only that calendar day.
    PERFORM pg_temp.assert_summary(org_admin,'2026-11-20',
        'Alpha/A1 Assigned=1/0; Alpha/A2 Empty=0/0; Bravo/B1 Other brand=0/0');
    -- No assignment, no identity: no report access.
    PERFORM pg_temp.assert_can_report(no_assignment,false,'unassigned user');
    PERFORM pg_temp.assert_summary(no_assignment,'2026-11-19','');
    PERFORM pg_temp.assert_can_report(NULL,false,'missing identity');
    PERFORM pg_temp.assert_summary(NULL,'2026-11-19','');

    -- Inactive users, stores and brands drop out.
    UPDATE public.users SET is_active=false WHERE id=manager;
    PERFORM pg_temp.assert_can_report(manager,false,'inactive manager');
    PERFORM pg_temp.assert_summary(manager,'2026-11-19','');
    UPDATE public.users SET is_active=true WHERE id=manager;
    UPDATE public.locations SET is_active=false WHERE id=a2;
    PERFORM pg_temp.assert_summary(brand_admin,'2026-11-19','Alpha/A1 Assigned=2/1');
    UPDATE public.locations SET is_active=true WHERE id=a2;
    UPDATE public.brands SET is_active=false WHERE id=brand_a;
    PERFORM pg_temp.assert_summary(org_admin,'2026-11-19','Bravo/B1 Other brand=1/0');
    -- With A1 inactive, the mixed user's only remaining role is employee at B1.
    PERFORM pg_temp.assert_can_report(mixed,false,'mixed user with inactive managed brand');
    PERFORM pg_temp.assert_summary(mixed,'2026-11-19','');
    UPDATE public.brands SET is_active=true WHERE id=brand_a;

    -- Removing the manager assignment removes access.
    DELETE FROM public.user_locations WHERE user_id=manager;
    PERFORM pg_temp.assert_can_report(manager,false,'manager after removal');
    PERFORM pg_temp.assert_summary(manager,'2026-11-19','');
    PERFORM pg_temp.assert_summary(mixed,'2026-11-19','Alpha/A1 Assigned=2/1');

    -- Occurrences cancelled by definition deactivation are not counted.
    UPDATE public.task_instances SET cancelled_at=now(), cancelled_by=org_admin
    WHERE location_id=a1 AND scheduled_day='2026-11-20';
    PERFORM pg_temp.assert_summary(org_admin,'2026-11-20',
        'Alpha/A1 Assigned=0/0; Alpha/A2 Empty=0/0; Bravo/B1 Other brand=0/0');
END;
$$;
ROLLBACK;
