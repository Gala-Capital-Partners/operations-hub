BEGIN;

-- ============================================================
-- TEST HELPERS
-- ============================================================

CREATE TEMP TABLE verification_results (
    test_number integer GENERATED ALWAYS AS IDENTITY,
    test_name text NOT NULL,
    result text NOT NULL
);

-- Record a successful assertion, or stop if it fails.
CREATE FUNCTION pg_temp.assert_true(
    condition boolean,
    test_name text
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF condition IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL: %', test_name;
    END IF;

    INSERT INTO pg_temp.verification_results (test_name, result)
    VALUES (test_name, 'PASS');
END;
$$;

-- Execute an operation that should fail.
-- Check the error code and, optionally, the constraint name.
CREATE FUNCTION pg_temp.expect_error(
    statement text,
    expected_state text,
    test_name text,
    expected_constraint text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    actual_state text;
    actual_constraint text;
BEGIN
    BEGIN
        EXECUTE statement;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS
            actual_state = RETURNED_SQLSTATE,
            actual_constraint = CONSTRAINT_NAME;

        IF actual_state IS DISTINCT FROM expected_state THEN
            RAISE EXCEPTION
                'FAIL [%]: expected error %, got %: %',
                test_name, expected_state, actual_state, SQLERRM;
        END IF;

        IF expected_constraint IS NOT NULL
           AND actual_constraint IS DISTINCT FROM expected_constraint THEN
            RAISE EXCEPTION
                'FAIL [%]: expected constraint %, got %',
                test_name, expected_constraint, actual_constraint;
        END IF;

        INSERT INTO pg_temp.verification_results (test_name, result)
        VALUES (test_name, 'PASS');

        RETURN;
    END;

    RAISE EXCEPTION
        'FAIL [%]: operation unexpectedly succeeded', test_name;
END;
$$;

-- Error codes:
-- 23503 = foreign-key violation
-- 23505 = unique violation
-- 23514 = check violation

DO $$
DECLARE
    org_a uuid := gen_random_uuid();
    org_b uuid := gen_random_uuid();

    brand_a uuid := gen_random_uuid();
    brand_a_two uuid := gen_random_uuid();
    brand_b uuid := gen_random_uuid();

    store_a uuid := gen_random_uuid();
    store_a_two uuid := gen_random_uuid();
    store_a_other_brand uuid := gen_random_uuid();
    store_b uuid := gen_random_uuid();

    person uuid := gen_random_uuid();
    second_person uuid := gen_random_uuid();
    missing_brand uuid := gen_random_uuid();

    org_role uuid := gen_random_uuid();
    brand_role uuid := gen_random_uuid();
    manager_role uuid := gen_random_uuid();
    employee_role uuid := gen_random_uuid();

    test_permission uuid := gen_random_uuid();

    key_prefix text;
    test_email text;
    brand_slug text;
    permission_key text;

    bad_value text;
    timestamp_case record;
    actual_timestamp timestamptz;
BEGIN
    -- ========================================================
    -- 1. SCHEMA STRUCTURE
    -- ========================================================

    PERFORM pg_temp.assert_true(
        (
            SELECT count(*) = 9
            FROM pg_catalog.pg_tables
            WHERE schemaname = 'public'
              AND tablename IN (
                  'organizations', 'users', 'brands',
                  'locations', 'roles', 'permissions',
                  'role_permissions', 'user_roles', 'user_locations'
              )
        ),
        'All nine application tables exist'
    );

    PERFORM pg_temp.assert_true(
        (
            SELECT count(*) = 9 AND bool_and(rowsecurity)
            FROM pg_catalog.pg_tables
            WHERE schemaname = 'public'
              AND tablename IN (
                  'organizations', 'users', 'brands',
                  'locations', 'roles', 'permissions',
                  'role_permissions', 'user_roles', 'user_locations'
              )
        ),
        'RLS is enabled on all nine tables'
    );

    PERFORM pg_temp.assert_true(
        (
            SELECT count(*) = 6
            FROM information_schema.triggers
            WHERE trigger_schema = 'public'
              AND action_timing = 'BEFORE'
              AND event_manipulation = 'UPDATE'
              AND (
                  event_object_table,
                  trigger_name
              ) IN (
                  ('organizations', 'organizations_set_updated_at'),
                  ('users', 'users_set_updated_at'),
                  ('brands', 'brands_set_updated_at'),
                  ('locations', 'locations_set_updated_at'),
                  ('roles', 'roles_set_updated_at'),
                  ('user_locations', 'user_locations_set_updated_at')
              )
        ),
        'All six BEFORE UPDATE triggers exist'
    );

    -- ========================================================
    -- 2. SHARED TEST FIXTURES
    -- ========================================================

    -- A random lowercase-only prefix that satisfies key checks.
    key_prefix := 'verification_' ||
        translate(
            replace(gen_random_uuid()::text, '-', ''),
            '0123456789', 'ghijklmnop'
        );

    test_email := person::text || '@example.invalid';
    brand_slug := 'test-' || brand_a::text;
    permission_key := key_prefix || '.read';

    INSERT INTO public.organizations (id, name, updated_at)
    VALUES
        (org_a, 'Verification Organization A', '2000-01-01 00:00:00+00'),
        (org_b, 'Verification Organization B', '2000-01-01 00:00:00+00');

    INSERT INTO public.brands (
        id, organization_id, name, slug, updated_at
    )
    VALUES
        (
            brand_a, org_a, 'Brand A', brand_slug,
            '2000-01-01 00:00:00+00'
        ),
        (
            brand_a_two, org_a, 'Brand A Two',
            'test-' || brand_a_two::text,
            '2000-01-01 00:00:00+00'
        ),
        (
            brand_b, org_b, 'Brand B',
            'test-' || brand_b::text,
            '2000-01-01 00:00:00+00'
        );

    -- Minimal Auth identities for local database tests only.
    -- Real accounts must be provisioned through Supabase Auth.
    INSERT INTO auth.users (id)
    VALUES (person), (second_person);

    INSERT INTO public.users (
        id, organization_id, email, full_name, updated_at
    )
    VALUES (
        person, org_a, test_email,
        'Verification User', '2000-01-01 00:00:00+00'
    );

    INSERT INTO public.roles (
        id, key, name, scope, updated_at
    )
    VALUES
        (
            org_role, key_prefix || '_org',
            'Test Organization Admin', 'organization',
            '2000-01-01 00:00:00+00'
        ),
        (
            brand_role, key_prefix || '_brand',
            'Test Brand Admin', 'brand',
            '2000-01-01 00:00:00+00'
        ),
        (
            manager_role, key_prefix || '_manager',
            'Test Manager', 'location',
            '2000-01-01 00:00:00+00'
        ),
        (
            employee_role, key_prefix || '_employee',
            'Test Employee', 'location',
            '2000-01-01 00:00:00+00'
        );

    PERFORM pg_temp.assert_true(
        (
            SELECT count(*) = 4
            FROM public.roles
            WHERE id IN (
                org_role, brand_role, manager_role, employee_role
            )
        ),
        'Valid organization, brand, and location scopes are accepted'
    );

    INSERT INTO public.permissions (id, key, description)
    VALUES (
        test_permission, permission_key, 'Verification permission'
    );

    -- ========================================================
    -- 3. ROLE-SCOPE VALUES
    -- ========================================================

    PERFORM pg_temp.expect_error(
        format(
            'INSERT INTO public.roles (key, name, scope)
             VALUES (%L, %L, %L)',
            key_prefix || '_invalid', 'Invalid Scope', 'global'
        ),
        '23514',
        'Invalid role scope is rejected'
    );

    -- ========================================================
    -- 4. LOCATION PARENT AND STORE-NUMBER RULES
    -- ========================================================

    PERFORM pg_temp.expect_error(
        format(
            'INSERT INTO public.locations (brand_id, name, timezone)
             VALUES (%L, %L, %L)',
            missing_brand, 'Missing Brand Store', 'America/Los_Angeles'
        ),
        '23503',
        'A location cannot reference a nonexistent brand',
        'locations_brands_fks'
    );

    -- The same store number is valid in different brands.
    INSERT INTO public.locations (
        id, brand_id, store_number, name, timezone, updated_at
    )
    VALUES
        (
            store_a, brand_a, '001', 'Store A',
            'America/Los_Angeles', '2000-01-01 00:00:00+00'
        ),
        (
            store_a_two, brand_a, '002', 'Store A Two',
            'America/Los_Angeles', '2000-01-01 00:00:00+00'
        ),
        (
            store_a_other_brand, brand_a_two, '001', 'Other Brand Store',
            'America/Los_Angeles', '2000-01-01 00:00:00+00'
        ),
        (
            store_b, brand_b, '001', 'Store B',
            'America/Los_Angeles', '2000-01-01 00:00:00+00'
        );

    PERFORM pg_temp.assert_true(
        (
            SELECT count(*) = 3
            FROM public.locations
            WHERE id IN (store_a, store_a_other_brand, store_b)
              AND store_number = '001'
        ),
        'Different brands can use the same store number'
    );

    PERFORM pg_temp.expect_error(
        format(
            'INSERT INTO public.locations
             (brand_id, store_number, name, timezone)
             VALUES (%L, %L, %L, %L)',
            brand_a, '001', 'Duplicate Store', 'America/Los_Angeles'
        ),
        '23505',
        'Duplicate store numbers within one brand are rejected',
        'location_brand_id_store_number_unique'
    );

    INSERT INTO public.locations (
        brand_id, store_number, name, timezone
    )
    VALUES
        (brand_a, NULL, 'Unknown Number One', 'America/Los_Angeles'),
        (brand_a, NULL, 'Unknown Number Two', 'America/Los_Angeles');

    PERFORM pg_temp.assert_true(
        (
            SELECT count(*) = 2
            FROM public.locations
            WHERE brand_id = brand_a
              AND store_number IS NULL
        ),
        'Multiple NULL store numbers within a brand are allowed'
    );

    -- ========================================================
    -- 5. USER_ROLES ORGANIZATION CONSISTENCY
    -- ========================================================

    PERFORM pg_temp.expect_error(
        format(
            'INSERT INTO public.user_roles
             (user_id, organization_id, role_id, role_scope, brand_id)
             VALUES (%L, %L, %L, %L, %L)',
            person, org_a, brand_role, 'brand', brand_b
        ),
        '23503',
        'Brand assignment rejects a brand from another organization',
        'user_roles_brands_fks'
    );

    PERFORM pg_temp.expect_error(
        format(
            'INSERT INTO public.user_roles
             (user_id, organization_id, role_id, role_scope, brand_id)
             VALUES (%L, %L, %L, %L, %L)',
            person, org_b, brand_role, 'brand', brand_b
        ),
        '23503',
        'Brand assignment rejects the wrong user organization',
        'user_roles_users_fks'
    );

    -- ========================================================
    -- 6. ASSIGNMENT SCOPE AND BRAND TARGET
    -- ========================================================

    PERFORM pg_temp.expect_error(
        format(
            'INSERT INTO public.user_roles
             (user_id, organization_id, role_id, role_scope, brand_id)
             VALUES (%L, %L, %L, %L, %L)',
            person, org_a, org_role, 'organization', brand_a
        ),
        '23514',
        'Organization assignments cannot have a brand target',
        'user_roles_brand_scope_check'
    );

    PERFORM pg_temp.expect_error(
        format(
            'INSERT INTO public.user_roles
             (user_id, organization_id, role_id, role_scope, brand_id)
             VALUES (%L, %L, %L, %L, NULL)',
            person, org_a, brand_role, 'brand'
        ),
        '23514',
        'Brand assignments require a brand target',
        'user_roles_brand_scope_check'
    );

    -- The target shape is valid, but the actual role is brand-scoped.
    PERFORM pg_temp.expect_error(
        format(
            'INSERT INTO public.user_roles
             (user_id, organization_id, role_id, role_scope, brand_id)
             VALUES (%L, %L, %L, %L, NULL)',
            person, org_a, brand_role, 'organization'
        ),
        '23503',
        'Declared assignment scope must match the actual role',
        'user_roles_roles_fks'
    );

    -- Valid organization and brand assignments.
    INSERT INTO public.user_roles (
        user_id, organization_id, role_id, role_scope, brand_id
    )
    VALUES
        (person, org_a, org_role, 'organization', NULL),
        (person, org_a, brand_role, 'brand', brand_a);

    PERFORM pg_temp.assert_true(
        (
            SELECT count(*) = 2
            FROM public.user_roles
            WHERE user_id = person
        ),
        'Valid organization and brand assignments are accepted'
    );

    -- ========================================================
    -- 7. DUPLICATE USER_ROLES ASSIGNMENTS
    -- ========================================================

    PERFORM pg_temp.expect_error(
        format(
            'INSERT INTO public.user_roles
             (user_id, organization_id, role_id, role_scope, brand_id)
             VALUES (%L, %L, %L, %L, NULL)',
            person, org_a, org_role, 'organization'
        ),
        '23505',
        'Duplicate organization assignments with NULL brands are rejected',
        'user_roles_assignment_unique'
    );

    PERFORM pg_temp.expect_error(
        format(
            'INSERT INTO public.user_roles
             (user_id, organization_id, role_id, role_scope, brand_id)
             VALUES (%L, %L, %L, %L, %L)',
            person, org_a, brand_role, 'brand', brand_a
        ),
        '23505',
        'Duplicate brand assignments are rejected',
        'user_roles_assignment_unique'
    );

    -- ========================================================
    -- 8. USER_LOCATIONS RELATIONSHIPS AND SCOPE
    -- ========================================================

    -- Both brands belong to A, but the store belongs to brand_a_two.
    PERFORM pg_temp.expect_error(
        format(
            'INSERT INTO public.user_locations
             (user_id, location_id, organization_id, brand_id, role_id)
             VALUES (%L, %L, %L, %L, %L)',
            person, store_a_other_brand, org_a, brand_a, manager_role
        ),
        '23503',
        'A location assignment requires the correct store-brand pair',
        'user_locations_locations_fk'
    );

    PERFORM pg_temp.expect_error(
        format(
            'INSERT INTO public.user_locations
             (user_id, location_id, organization_id, brand_id, role_id)
             VALUES (%L, %L, %L, %L, %L)',
            person, store_b, org_b, brand_b, manager_role
        ),
        '23503',
        'Location assignment rejects the wrong user organization',
        'user_locations_users_fk'
    );

    PERFORM pg_temp.expect_error(
        format(
            'INSERT INTO public.user_locations
             (user_id, location_id, organization_id, brand_id, role_id)
             VALUES (%L, %L, %L, %L, %L)',
            person, store_b, org_a, brand_b, manager_role
        ),
        '23503',
        'Location assignment rejects a brand from another organization',
        'user_locations_brands_fk'
    );

    PERFORM pg_temp.expect_error(
        format(
            'INSERT INTO public.user_locations
             (user_id, location_id, organization_id, brand_id, role_id)
             VALUES (%L, %L, %L, %L, %L)',
            person, store_a, org_a, brand_a, brand_role
        ),
        '23503',
        'A brand role cannot be relabeled as a location role',
        'user_locations_roles_fk'
    );

    PERFORM pg_temp.expect_error(
        format(
            'INSERT INTO public.user_locations
             (user_id, location_id, organization_id,
              brand_id, role_id, role_scope)
             VALUES (%L, %L, %L, %L, %L, %L)',
            person, store_a, org_a, brand_a, brand_role, 'brand'
        ),
        '23514',
        'user_locations rejects non-location scope',
        'user_locations_role_scope_check'
    );

    -- ========================================================
    -- 9. ONE ROLE PER USER PER STORE
    -- ========================================================

    INSERT INTO public.user_locations (
        user_id, location_id, organization_id,
        brand_id, role_id, updated_at
    )
    VALUES
        (
            person, store_a, org_a,
            brand_a, manager_role, '2000-01-01 00:00:00+00'
        ),
        (
            person, store_a_two, org_a,
            brand_a, employee_role, '2000-01-01 00:00:00+00'
        );

    PERFORM pg_temp.assert_true(
        (
            SELECT count(*) = 2
            FROM public.user_locations
            WHERE user_id = person
        ),
        'A user can hold different roles at different stores'
    );

    PERFORM pg_temp.assert_true(
        (
            SELECT bool_and(role_scope = 'location')
            FROM public.user_locations
            WHERE user_id = person
        ),
        'Location assignment scope defaults to location'
    );

    PERFORM pg_temp.expect_error(
        format(
            'INSERT INTO public.user_locations
             (user_id, location_id, organization_id, brand_id, role_id)
             VALUES (%L, %L, %L, %L, %L)',
            person, store_a, org_a, brand_a, employee_role
        ),
        '23505',
        'A second role at the same user-store pair is rejected',
        'user_location_pk'
    );

    -- ========================================================
    -- 10. ROLE-PERMISSION LINKS
    -- ========================================================

    INSERT INTO public.role_permissions (role_id, permission_id)
    VALUES
        (manager_role, test_permission),
        (brand_role, test_permission);

    PERFORM pg_temp.assert_true(
        (
            SELECT count(*) = 2
            FROM public.role_permissions
            WHERE permission_id = test_permission
        ),
        'Different roles can grant the same permission'
    );

    PERFORM pg_temp.expect_error(
        format(
            'INSERT INTO public.role_permissions (role_id, permission_id)
             VALUES (%L, %L)',
            manager_role, test_permission
        ),
        '23505',
        'Duplicate role-permission links are rejected',
        'role_permissions_pk'
    );

    -- ========================================================
    -- 11. FIELD UNIQUENESS
    -- ========================================================

    PERFORM pg_temp.expect_error(
        format(
            'INSERT INTO public.users
             (id, organization_id, email, full_name)
             VALUES (%L, %L, %L, %L)',
            second_person, org_a, upper(test_email), 'Duplicate Email'
        ),
        '23505',
        'Email uniqueness is case-insensitive',
        'users_email_lower_unique'
    );

    PERFORM pg_temp.expect_error(
        format(
            'INSERT INTO public.roles (key, name, scope)
             VALUES (%L, %L, %L)',
            key_prefix || '_manager', 'Duplicate Role', 'location'
        ),
        '23505',
        'Duplicate role keys are rejected',
        'roles_key_unique'
    );

    PERFORM pg_temp.expect_error(
        format(
            'INSERT INTO public.permissions (key, description)
             VALUES (%L, %L)',
            permission_key, 'Duplicate Permission'
        ),
        '23505',
        'Duplicate permission keys are rejected',
        'permission_key_unique'
    );

    PERFORM pg_temp.expect_error(
        format(
            'INSERT INTO public.brands (organization_id, name, slug)
             VALUES (%L, %L, %L)',
            org_b, 'Duplicate Slug Brand', brand_slug
        ),
        '23505',
        'Brand slugs are unique across organizations',
        'brands_slug_unique'
    );

    -- ========================================================
    -- 12. FIELD FORMAT CHECKS
    -- ========================================================

    FOREACH bad_value IN ARRAY ARRAY[
        'UpperCase',
        'has space',
        '_leading',
        'double__underscore'
    ] LOOP
        PERFORM pg_temp.expect_error(
            format(
                'INSERT INTO public.roles (key, name, scope)
                 VALUES (%L, %L, %L)',
                bad_value, 'Invalid Role Key', 'location'
            ),
            '23514',
            'Reject invalid role key: ' || bad_value
        );
    END LOOP;

    FOREACH bad_value IN ARRAY ARRAY[
        'users',
        'Users.read',
        'users.read.extra',
        'users.'
    ] LOOP
        PERFORM pg_temp.expect_error(
            format(
                'INSERT INTO public.permissions (key, description)
                 VALUES (%L, %L)',
                bad_value, 'Invalid Permission Key'
            ),
            '23514',
            'Reject invalid permission key: ' || bad_value
        );
    END LOOP;

    FOREACH bad_value IN ARRAY ARRAY[
        'Brand',
        'has space',
        '-leading',
        'trailing-',
        'double--hyphen'
    ] LOOP
        PERFORM pg_temp.expect_error(
            format(
                'INSERT INTO public.brands (organization_id, name, slug)
                 VALUES (%L, %L, %L)',
                org_a, 'Invalid Slug Brand', bad_value
            ),
            '23514',
            'Reject invalid brand slug: ' || bad_value,
            'brands_slug_format_check'
        );
    END LOOP;

    -- ========================================================
    -- 13. TIMESTAMP TRIGGER BEHAVIOR
    -- ========================================================

    -- Original test: change only the name.
    UPDATE public.organizations
    SET name = 'Verification Organization Updated'
    WHERE id = org_a
    RETURNING updated_at INTO actual_timestamp;

    PERFORM pg_temp.assert_true(
        actual_timestamp = now(),
        'Updating an organization name refreshes updated_at'
    );

    -- Check every other table with an id and updated_at.
    -- Explicitly supply an old timestamp; the trigger must replace it.
    FOR timestamp_case IN
        SELECT *
        FROM (VALUES
            ('users', person),
            ('brands', brand_a),
            ('locations', store_a),
            ('roles', manager_role)
        ) AS cases(table_name, row_id)
    LOOP
        actual_timestamp := NULL;

        EXECUTE format(
            'UPDATE public.%I
             SET updated_at = %L::timestamptz
             WHERE id = %L
             RETURNING updated_at',
            timestamp_case.table_name,
            '2000-01-01 00:00:00+00',
            timestamp_case.row_id
        )
        INTO actual_timestamp;

        PERFORM pg_temp.assert_true(
            actual_timestamp = now(),
            'Timestamp trigger works: ' || timestamp_case.table_name
        );
    END LOOP;

    actual_timestamp := NULL;

    UPDATE public.user_locations
    SET updated_at = '2000-01-01 00:00:00+00'
    WHERE user_id = person
      AND location_id = store_a
    RETURNING updated_at INTO actual_timestamp;

    PERFORM pg_temp.assert_true(
        actual_timestamp = now(),
        'Timestamp trigger works: user_locations'
    );

    -- ========================================================
    -- 14. DELETION RESTRICTIONS
    -- ========================================================

    PERFORM pg_temp.expect_error(
        format(
            'DELETE FROM public.roles WHERE id = %L',
            manager_role
        ),
        '23503',
        'Cannot delete a role assigned through user_locations',
        'user_locations_roles_fk'
    );

    PERFORM pg_temp.expect_error(
        format(
            'DELETE FROM public.roles WHERE id = %L',
            brand_role
        ),
        '23503',
        'Cannot delete a role assigned through user_roles',
        'user_roles_roles_fks'
    );

    -- Multiple foreign keys can block these parent deletions.
    PERFORM pg_temp.expect_error(
        format(
            'DELETE FROM public.brands WHERE id = %L',
            brand_a
        ),
        '23503',
        'Cannot delete a brand with dependent records'
    );

    PERFORM pg_temp.expect_error(
        format(
            'DELETE FROM public.organizations WHERE id = %L',
            org_a
        ),
        '23503',
        'Cannot delete an organization with dependent records'
    );

    PERFORM pg_temp.expect_error(
        format(
            'DELETE FROM auth.users WHERE id = %L',
            person
        ),
        '23503',
        'Cannot delete Auth identity while application profile exists',
        'users_auth_user_fk'
    );

    -- ========================================================
    -- 15. DELETION CASCADES
    -- ========================================================

    DELETE FROM public.locations
    WHERE id = store_a_two;

    PERFORM pg_temp.assert_true(
        NOT EXISTS (
            SELECT 1
            FROM public.user_locations
            WHERE location_id = store_a_two
        ),
        'Deleting a location removes its assignments'
    );

    PERFORM pg_temp.assert_true(
        EXISTS (
            SELECT 1
            FROM public.user_locations
            WHERE user_id = person
              AND location_id = store_a
        ),
        'Deleting one location preserves other location assignments'
    );

    DELETE FROM public.users
    WHERE id = person;

    PERFORM pg_temp.assert_true(
        NOT EXISTS (
            SELECT 1 FROM public.user_roles
            WHERE user_id = person
        )
        AND NOT EXISTS (
            SELECT 1 FROM public.user_locations
            WHERE user_id = person
        ),
        'Deleting an application user removes both assignment types'
    );

    PERFORM pg_temp.assert_true(
        EXISTS (
            SELECT 1 FROM auth.users
            WHERE id = person
        ),
        'Deleting an application profile preserves the Auth identity'
    );

    -- Now that assignments are gone, deleting this role is allowed.
    DELETE FROM public.roles
    WHERE id = manager_role;

    PERFORM pg_temp.assert_true(
        NOT EXISTS (
            SELECT 1 FROM public.role_permissions
            WHERE role_id = manager_role
        ),
        'Deleting an unassigned role removes its permission links'
    );

    PERFORM pg_temp.assert_true(
        EXISTS (
            SELECT 1 FROM public.role_permissions
            WHERE role_id = brand_role
              AND permission_id = test_permission
        ),
        'Deleting one role preserves another role permission link'
    );

    DELETE FROM public.permissions
    WHERE id = test_permission;

    PERFORM pg_temp.assert_true(
        NOT EXISTS (
            SELECT 1 FROM public.role_permissions
            WHERE permission_id = test_permission
        ),
        'Deleting a permission removes its remaining role links'
    );
END;
$$;

-- One PASS row per assertion.
-- Any unexpected behavior raises an exception instead.
SELECT test_number, test_name, result
FROM pg_temp.verification_results
ORDER BY test_number;

-- Remove all fixtures, temporary helpers, and test results.
ROLLBACK;