-- Initial catalog from the approved matrix in docs/db-design.md:
-- 4 roles, 11 permissions, and 32 role-permission mappings.
-- Maintain this shared catalog through reviewed migrations, not runtime APIs.
-- This migration defines grants; it does not assign users or implement RLS policies.

-- Shared role definitions. Assignments identify the target organization,
-- brand, or location; a broader scope does not grant every action.

INSERT INTO public.roles (key, name, description, scope)
VALUES
    (
        'org_admin',
        'Organization Admin',
        'Organization-level administrative role.',
        'organization'
    ),
    (
        'brand_admin',
        'Brand Admin',
        'Brand-level administrative role.',
        'brand'
    ),
    (
        'location_manager',
        'Location Manager',
        'Management role for an assigned location.',
        'location'
    ),
    (
        'employee',
        'Employee',
        'Employee role for an assigned location.',
        'location'
    );

-- Shared permission definitions. Authorization must check both the action
-- and its target. Self-only reads and role-assignment restrictions are
-- additional rules enforced by the authorization layer and policies.
INSERT INTO public.permissions (key, description)
VALUES
    (
        'locations.read',
        'View locations'
    ),
    (
        'users.read',
        'View user profiles'
    ),
    (
        'users.invite',
        'Invite users'
    ),
    (
        'users.deactivate',
        'Deactivate application accounts'
    ),
    (
        'role_assignments.read',
        'View role assignments'
    ),
    (
        'role_assignments.manage',
        'Grant, replace, or revoke role assignments'
    ),
    (
        'tasks.manage',
        'Create/edit recurring task definitions'
    ),
    (
        'task_instances.read',
        'View daily task instances'
    ),
    (
        'task_instances.complete',
        'Mark task instances complete'
    ),
    (
        'task_instances.reopen',
        'Reopen completed task instances'
    ),
    (
        'reports.read',
        'View completion reports'
    );

-- Map existing role and permission keys to their generated UUIDs.
-- Inner joins skip unknown keys: verification must check the exact pairs,
-- not just successful execution or the total row count.
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT
    r.id,
    p.id
FROM (
    VALUES
        -- Organization Admin: 9 permissions
        -- Account deactivation is organization-wide. Task completion and
        -- reopening require a separate applicable location-role grant.
        ('org_admin', 'locations.read'),
        ('org_admin', 'users.read'),
        ('org_admin', 'users.invite'),
        ('org_admin', 'users.deactivate'),
        ('org_admin', 'role_assignments.read'),
        ('org_admin', 'role_assignments.manage'),
        ('org_admin', 'tasks.manage'),
        ('org_admin', 'task_instances.read'),
        ('org_admin', 'reports.read'),

        -- Brand Admin: 8 permissions
        -- May manage location-manager and employee assignments in this brand,
        -- but cannot grant/revoke brand-admin or organization-admin assignments.
        ('brand_admin', 'locations.read'),
        ('brand_admin', 'users.read'),
        ('brand_admin', 'users.invite'),
        ('brand_admin', 'role_assignments.read'),
        ('brand_admin', 'role_assignments.manage'),
        ('brand_admin', 'tasks.manage'),
        ('brand_admin', 'task_instances.read'),
        ('brand_admin', 'reports.read'),

        -- Location Manager: 10 permissions
        -- Invitations require authority over the proposed role and location.
        -- Assignment management is limited to employee assignments at managed
        -- locations; validate both old and new assignments when replacing one.
        ('location_manager', 'locations.read'),
        ('location_manager', 'users.read'),
        ('location_manager', 'users.invite'),
        ('location_manager', 'role_assignments.read'),
        ('location_manager', 'role_assignments.manage'),
        ('location_manager', 'tasks.manage'),
        ('location_manager', 'task_instances.read'),
        ('location_manager', 'task_instances.complete'),
        ('location_manager', 'task_instances.reopen'),
        ('location_manager', 'reports.read'),

        -- Employee: 5 permissions
        -- Profile and assignment reads must be limited to self.
        ('employee', 'locations.read'),
        ('employee', 'users.read'),
        ('employee', 'role_assignments.read'),
        ('employee', 'task_instances.read'),
        ('employee', 'task_instances.complete')
) AS grants(role_key, permission_key)
JOIN public.roles AS r
    ON r.key = grants.role_key
JOIN public.permissions AS p
    ON p.key = grants.permission_key;
