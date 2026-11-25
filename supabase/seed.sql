-- Local development seed data. SYNTHETIC ONLY: no sponsor data.
--
-- Loaded by `npx supabase start` (fresh stack) and `npx supabase db reset --local`
-- (see [db.seed] in config.toml). `supabase db push`, which the shared-project
-- deploy workflow uses, does not load seeds, so this never reaches the hosted project.
--
-- Creates one organization with two brands and seven locations, five sign-in
-- accounts covering every role, brand-wide and location-specific task definitions,
-- and task instances from three days ago to seven days ahead of the day the seed runs
-- (there is no instance generator yet). Most past instances are completed, with
-- matching completion events.
--
-- Test accounts (local only), all with password: opshub-local-dev
--   alex.chen@opshub.test      Organization Admin (whole organization)
--   maria.santos@opshub.test   Brand Admin        (BurgerCraft)
--   jordan.lee@opshub.test     Location Manager   (BurgerCraft Downtown Flagship)
--   sam.rivera@opshub.test     Employee           (BurgerCraft Downtown Flagship)
--   taylor.kim@opshub.test     Location Manager   (Taco Verde Harbor View)
--
-- Fixed UUIDs keep the data easy to reference in curl examples and tests.

BEGIN;

-- ---------------------------------------------------------------------------
-- Directory: organization, brands, locations
-- ---------------------------------------------------------------------------

INSERT INTO public.organizations (id, name) VALUES
    ('00000000-0000-4000-a000-000000000001', 'OpsHub Demo Restaurant Group');

INSERT INTO public.brands (id, organization_id, name, slug) VALUES
    ('00000000-0000-4000-b000-000000000001', '00000000-0000-4000-a000-000000000001', 'BurgerCraft', 'burgercraft'),
    ('00000000-0000-4000-b000-000000000002', '00000000-0000-4000-a000-000000000001', 'Taco Verde', 'tacoverde');

INSERT INTO public.locations (id, brand_id, store_number, name, address_line1, city, state, postal_code, timezone) VALUES
    ('00000000-0000-4000-c000-000000000001', '00000000-0000-4000-b000-000000000001', 'BC-001', 'Downtown Flagship',   '100 Main St',        'Irvine',      'CA', '92614', 'America/Los_Angeles'),
    ('00000000-0000-4000-c000-000000000002', '00000000-0000-4000-b000-000000000001', 'BC-002', 'Midtown Mall',        '250 Market Ave',     'Irvine',      'CA', '92618', 'America/Los_Angeles'),
    ('00000000-0000-4000-c000-000000000003', '00000000-0000-4000-b000-000000000001', 'BC-003', 'Airport Terminal B',  '18601 Airport Way',  'Santa Ana',   'CA', '92707', 'America/Los_Angeles'),
    ('00000000-0000-4000-c000-000000000004', '00000000-0000-4000-b000-000000000001', 'BC-004', 'North Park',          '3010 University Ave','San Diego',   'CA', '92104', 'America/Los_Angeles'),
    ('00000000-0000-4000-c000-000000000005', '00000000-0000-4000-b000-000000000002', 'TV-001', 'Westside Commons',    '410 Commons Blvd',   'Dallas',      'TX', '75201', 'America/Chicago'),
    ('00000000-0000-4000-c000-000000000006', '00000000-0000-4000-b000-000000000002', 'TV-002', 'Harbor View',         '75 Harbor Dr',       'Dallas',      'TX', '75202', 'America/Chicago'),
    ('00000000-0000-4000-c000-000000000007', '00000000-0000-4000-b000-000000000002', 'TV-003', 'University District', '900 College St',     'Austin',      'TX', '78705', 'America/Chicago');

-- ---------------------------------------------------------------------------
-- Sign-in accounts (Supabase Auth) and application profiles
-- ---------------------------------------------------------------------------

CREATE TEMP TABLE seed_people (id uuid, email text, full_name text) ON COMMIT DROP;
INSERT INTO seed_people VALUES
    ('00000000-0000-4000-d000-000000000001', 'alex.chen@opshub.test',    'Alex Chen'),
    ('00000000-0000-4000-d000-000000000002', 'maria.santos@opshub.test', 'Maria Santos'),
    ('00000000-0000-4000-d000-000000000003', 'jordan.lee@opshub.test',   'Jordan Lee'),
    ('00000000-0000-4000-d000-000000000004', 'sam.rivera@opshub.test',   'Sam Rivera'),
    ('00000000-0000-4000-d000-000000000005', 'taylor.kim@opshub.test',   'Taylor Kim');

-- Empty strings (not NULL) in the token columns are what Supabase Auth expects
-- for accounts created directly in SQL.
INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change
)
SELECT
    '00000000-0000-0000-0000-000000000000', p.id, 'authenticated', 'authenticated', p.email,
    extensions.crypt('opshub-local-dev', extensions.gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('full_name', p.full_name), now(), now(),
    '', '', '', ''
FROM seed_people p;

INSERT INTO auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
SELECT
    p.id::text, p.id,
    jsonb_build_object('sub', p.id::text, 'email', p.email, 'email_verified', true),
    'email', now(), now(), now()
FROM seed_people p;

INSERT INTO public.users (id, organization_id, email, full_name)
SELECT p.id, '00000000-0000-4000-a000-000000000001', p.email, p.full_name
FROM seed_people p;

-- ---------------------------------------------------------------------------
-- Role assignments
-- ---------------------------------------------------------------------------

INSERT INTO public.user_roles (user_id, organization_id, role_id, role_scope, brand_id)
SELECT a.user_id, '00000000-0000-4000-a000-000000000001', r.id, r.scope, a.brand_id
FROM (VALUES
    ('00000000-0000-4000-d000-000000000001'::uuid, 'org_admin',   NULL::uuid),
    ('00000000-0000-4000-d000-000000000002'::uuid, 'brand_admin', '00000000-0000-4000-b000-000000000001'::uuid)
) AS a(user_id, role_key, brand_id)
JOIN public.roles r ON r.key = a.role_key;

INSERT INTO public.user_locations (user_id, location_id, organization_id, brand_id, role_id)
SELECT a.user_id, a.location_id, '00000000-0000-4000-a000-000000000001', l.brand_id, r.id
FROM (VALUES
    ('00000000-0000-4000-d000-000000000003'::uuid, '00000000-0000-4000-c000-000000000001'::uuid, 'location_manager'),
    ('00000000-0000-4000-d000-000000000004'::uuid, '00000000-0000-4000-c000-000000000001'::uuid, 'employee'),
    ('00000000-0000-4000-d000-000000000005'::uuid, '00000000-0000-4000-c000-000000000006'::uuid, 'location_manager')
) AS a(user_id, location_id, role_key)
JOIN public.locations l ON l.id = a.location_id
JOIN public.roles r ON r.key = a.role_key;

-- ---------------------------------------------------------------------------
-- Task definitions
-- location_id NULL = applies to every location in the brand.
-- ---------------------------------------------------------------------------

INSERT INTO public.task_definitions (
    id, brand_id, location_id, created_by, name, description, category,
    recurrence_rule, start_date, due_time, schedule_mode, scheduled_times,
    numeric_unit, numeric_min, numeric_max
) VALUES
    -- BurgerCraft, brand-wide (created by the brand admin)
    ('00000000-0000-4000-e000-000000000001', '00000000-0000-4000-b000-000000000001', NULL, '00000000-0000-4000-d000-000000000002',
     'Log walk-in cooler temperature', 'Read the walk-in thermometer and record the temperature.', 'Opening',
     'FREQ=DAILY', DATE '2026-11-01', TIME '08:00', 'all_day', '{}', '°F', -10, 60),
    ('00000000-0000-4000-e000-000000000002', '00000000-0000-4000-b000-000000000001', NULL, '00000000-0000-4000-d000-000000000002',
     'Check sanitizer concentration at all stations', 'Test each sanitizer bucket with a strip; replace any below 200 ppm.', 'Opening',
     'FREQ=DAILY', DATE '2026-11-01', TIME '09:00', 'all_day', '{}', NULL, NULL, NULL),
    ('00000000-0000-4000-e000-000000000003', '00000000-0000-4000-b000-000000000001', NULL, '00000000-0000-4000-d000-000000000002',
     'Hot-holding temperature check', 'Probe every item in the hot-holding cabinet and record the lowest reading.', 'Midday',
     'FREQ=DAILY', DATE '2026-11-01', NULL, 'timed', '{11:00,15:00}', '°F', 0, 250),
    ('00000000-0000-4000-e000-000000000004', '00000000-0000-4000-b000-000000000001', NULL, '00000000-0000-4000-d000-000000000002',
     'Review prep levels with kitchen lead', 'Compare prep sheet to on-hand levels before the lunch rush.', 'Midday',
     'FREQ=DAILY', DATE '2026-11-01', TIME '10:30', 'all_day', '{}', NULL, NULL, NULL),
    ('00000000-0000-4000-e000-000000000005', '00000000-0000-4000-b000-000000000001', NULL, '00000000-0000-4000-d000-000000000002',
     'End-of-day cleaning checklist', 'Clean grills, fryers and prep surfaces; empty and sanitize drains.', 'Closing',
     'FREQ=DAILY', DATE '2026-11-01', TIME '22:00', 'all_day', '{}', NULL, NULL, NULL),
    ('00000000-0000-4000-e000-000000000006', '00000000-0000-4000-b000-000000000001', NULL, '00000000-0000-4000-d000-000000000002',
     'Deposit preparation and safe count', 'Count the safe, prepare the deposit and log any variance.', 'Closing',
     'FREQ=DAILY', DATE '2026-11-01', TIME '23:00', 'all_day', '{}', NULL, NULL, NULL),
    ('00000000-0000-4000-e000-000000000007', '00000000-0000-4000-b000-000000000001', NULL, '00000000-0000-4000-d000-000000000002',
     'Submit produce order for next week', 'Review usage and submit the produce order to the distributor.', 'Midday',
     'FREQ=WEEKLY;BYDAY=MO', DATE '2026-11-01', TIME '14:00', 'all_day', '{}', NULL, NULL, NULL),
    -- BurgerCraft, Downtown Flagship only (created by its manager)
    ('00000000-0000-4000-e000-000000000008', '00000000-0000-4000-b000-000000000001', '00000000-0000-4000-c000-000000000001', '00000000-0000-4000-d000-000000000003',
     'Test drive-thru headsets', 'Check every headset and the order-board speaker before opening.', 'Opening',
     'FREQ=DAILY', DATE '2026-11-01', TIME '07:30', 'all_day', '{}', NULL, NULL, NULL),
    -- Taco Verde, brand-wide (created by the organization admin)
    ('00000000-0000-4000-e000-000000000011', '00000000-0000-4000-b000-000000000002', NULL, '00000000-0000-4000-d000-000000000001',
     'Prep salsa bar and check date labels', 'Stock the salsa bar and discard anything past its label date.', 'Opening',
     'FREQ=DAILY', DATE '2026-11-01', TIME '10:00', 'all_day', '{}', NULL, NULL, NULL),
    ('00000000-0000-4000-e000-000000000012', '00000000-0000-4000-b000-000000000002', NULL, '00000000-0000-4000-d000-000000000001',
     'Fryer oil quality check', 'Test fryer oil and record total polar materials.', 'Midday',
     'FREQ=DAILY', DATE '2026-11-01', TIME '13:00', 'all_day', '{}', '% TPM', 0, 40),
    ('00000000-0000-4000-e000-000000000013', '00000000-0000-4000-b000-000000000002', NULL, '00000000-0000-4000-d000-000000000001',
     'Close out tortilla station', 'Wrap and label tortillas, clean the press and wipe down the station.', 'Closing',
     'FREQ=DAILY', DATE '2026-11-01', TIME '21:30', 'all_day', '{}', NULL, NULL, NULL);

-- ---------------------------------------------------------------------------
-- Task instances (what a future generator would create)
-- From three days before to seven days after each location's current local day.
-- ---------------------------------------------------------------------------

CREATE TEMP TABLE seed_slots ON COMMIT DROP AS
SELECT
    d.id AS definition_id, d.brand_id, l.id AS location_id, l.timezone,
    day::date AS scheduled_day,
    slot AS slot_time,                 -- NULL for all-day definitions
    (now() AT TIME ZONE l.timezone)::date AS local_today,
    d.name, d.description, d.category, d.due_time,
    d.numeric_unit, d.numeric_min, d.numeric_max
FROM public.task_definitions d
JOIN public.locations l
    ON l.brand_id = d.brand_id AND (d.location_id IS NULL OR d.location_id = l.id)
CROSS JOIN LATERAL generate_series(
    (now() AT TIME ZONE l.timezone)::date - 3,
    (now() AT TIME ZONE l.timezone)::date + 7,
    interval '1 day'
) AS day
LEFT JOIN LATERAL unnest(CASE WHEN d.schedule_mode = 'timed' THEN d.scheduled_times END) AS slot ON true
WHERE d.recurrence_rule = 'FREQ=DAILY'
   OR (d.recurrence_rule = 'FREQ=WEEKLY;BYDAY=MO' AND extract(isodow FROM day) = 1);

-- Who completes tasks at each location: its employee, else its manager, else the brand admin.
CREATE TEMP TABLE seed_completers ON COMMIT DROP AS
SELECT l.id AS location_id,
       coalesce(
           (SELECT ul.user_id FROM public.user_locations ul JOIN public.roles r ON r.id = ul.role_id
             WHERE ul.location_id = l.id ORDER BY (r.key = 'employee') DESC LIMIT 1),
           (SELECT ur.user_id FROM public.user_roles ur WHERE ur.brand_id = l.brand_id LIMIT 1),
           '00000000-0000-4000-d000-000000000001'::uuid
       ) AS user_id
FROM public.locations l;

INSERT INTO public.task_instances (
    brand_id, location_id, definition_id, scheduled_day, scheduled_at, is_all_day_snapshot,
    name_snapshot, description_snapshot, category_snapshot, due_time_snapshot, timezone_snapshot,
    numeric_unit_snapshot, numeric_min_snapshot, numeric_max_snapshot,
    completed_at, completed_by, recorded_value, notes
)
SELECT
    s.brand_id, s.location_id, s.definition_id, s.scheduled_day,
    CASE WHEN s.slot_time IS NULL
         THEN s.scheduled_day::timestamp AT TIME ZONE s.timezone
         ELSE (s.scheduled_day + s.slot_time) AT TIME ZONE s.timezone END,
    s.slot_time IS NULL,
    s.name, s.description, s.category,
    CASE WHEN s.slot_time IS NULL THEN s.due_time END,
    s.timezone, s.numeric_unit, s.numeric_min, s.numeric_max,
    c.completed_at, c.completed_by, c.recorded_value, c.notes
FROM seed_slots s
JOIN seed_completers who ON who.location_id = s.location_id
CROSS JOIN LATERAL (
    SELECT
        -- Past days: about 80% done. Today: only opening tasks at Downtown Flagship.
        (s.scheduled_day < s.local_today
            AND abs(hashtext(s.definition_id::text || s.location_id::text || s.scheduled_day::text)) % 5 <> 0)
        OR (s.scheduled_day = s.local_today
            AND s.location_id = '00000000-0000-4000-c000-000000000001'
            AND s.category = 'Opening') AS done
) AS state
CROSS JOIN LATERAL (
    SELECT
        CASE WHEN state.done THEN least(
            (s.scheduled_day + coalesce(s.slot_time, s.due_time, TIME '12:00') - interval '20 minutes')
                AT TIME ZONE s.timezone,
            now()
        ) END AS completed_at,
        CASE WHEN state.done THEN who.user_id END AS completed_by,
        CASE WHEN state.done AND s.numeric_unit IS NOT NULL THEN
            CASE s.numeric_unit WHEN '°F' THEN CASE WHEN s.numeric_max > 100 THEN 165 ELSE 37 END
                                WHEN '% TPM' THEN 14 END
        END AS recorded_value,
        CASE WHEN state.done AND s.scheduled_day = s.local_today - 1
                  AND s.definition_id = '00000000-0000-4000-e000-000000000005'
             THEN 'Drain in the dish pit is slow; maintenance ticket opened.' END AS notes
) AS c;

INSERT INTO public.task_instance_events (instance_id, actor_id, event_type, occurred_at, recorded_value, notes)
SELECT id, completed_by, 'completed', completed_at, recorded_value, notes
FROM public.task_instances
WHERE completed_at IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Brand onboarding fixture: a brand that is not in the client's theme config
-- (used by e2e/tests/supabase-auth.spec.ts)
-- ---------------------------------------------------------------------------

-- Synthetic, local-only brand-onboarding fixture, separate from the original demo organization.
-- Its first task comes from the real generator. Seeds run as postgres, which may only
-- call the scheduler entry points while temporarily acting as the scheduler role.
GRANT operations_hub_scheduler TO postgres WITH INHERIT FALSE, SET TRUE;

DO $$
DECLARE
    org uuid;
    brand uuid;
    manager uuid := gen_random_uuid();
    store uuid;
    empty_store uuid;
    definition uuid;
    email_address text := 'onboarding.manager@opshub.test';
    today date := (now() AT TIME ZONE 'America/Los_Angeles')::date;
BEGIN
    INSERT INTO public.organizations (name) VALUES ('Onboarding Demo Group') RETURNING id INTO org;
    INSERT INTO public.brands (organization_id, name, slug)
        VALUES (org, 'Harbor Kitchen', 'harbor-kitchen') RETURNING id INTO brand;
    INSERT INTO public.locations (brand_id, name, timezone)
        VALUES (brand, 'Harbor Central', 'America/Los_Angeles') RETURNING id INTO store;
    INSERT INTO public.locations (brand_id, name, timezone)
        VALUES (brand, 'Harbor West', 'America/Los_Angeles') RETURNING id INTO empty_store;

    INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
        confirmation_token, recovery_token, email_change_token_new, email_change)
    VALUES ('00000000-0000-0000-0000-000000000000', manager, 'authenticated', 'authenticated',
        email_address, extensions.crypt('opshub-local-dev', extensions.gen_salt('bf')), now(),
        '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', '');
    INSERT INTO auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
        VALUES (manager::text, manager, jsonb_build_object('sub', manager, 'email', email_address), 'email', now(), now());
    INSERT INTO public.users (id, organization_id, email, full_name)
        VALUES (manager, org, email_address, 'Harbor Manager');
    INSERT INTO public.user_locations (user_id, organization_id, brand_id, location_id, role_id)
        SELECT manager, org, brand, loc.id, r.id FROM (VALUES (store), (empty_store)) AS loc(id)
        CROSS JOIN public.roles r WHERE r.key = 'location_manager';

    INSERT INTO public.task_definitions (brand_id, location_id, created_by, name, description, category, start_date)
        VALUES (brand, store, manager, 'Check opening supplies', 'Count supplies before opening.', 'Opening', today)
        RETURNING id INTO definition;
    SET LOCAL ROLE operations_hub_scheduler;
    PERFORM public.scheduler_generate_task_instances(definition, ARRAY[today], d.definition_version)
    FROM public.scheduler_active_task_definitions() AS d WHERE d.id = definition;
    RESET ROLE;
END;
$$;

REVOKE operations_hub_scheduler FROM postgres;

COMMIT;
