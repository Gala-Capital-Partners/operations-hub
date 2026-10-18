# Identity and Access Database Design

**Status:** Approved initial permission matrices; database implementation in progress. Nine migrations implement the core schema, permission catalog, scoped reads, and audited location-assignment writes. Database regression and concurrency checks have passed in local isolated testing. Express integration and the remaining lifecycle workflows are pending; these changes have not been deployed to the shared Supabase database.

**Target:** PostgreSQL 17 for the current migrations and local test environment, Supabase Auth, Express + TypeScript, and Next.js. Although `UNIQUE NULLS NOT DISTINCT` requires only PostgreSQL 15+, the role-membership options in the access migrations require PostgreSQL 16+.

## Purpose and scope
There are nine core application tables, shown in the diagram below, plus the internal `identity_access.assignment_audit_log` described in the write-access section. Supabase's existing `auth.users` table is shown as `auth_users` for reference; the project does not create or manage its schema.

Task and checklist tables are designed separately. They will reference brands, locations, and users and follow the same consistency and access conventions. Production deployment is outside the capstone scope.

## Key design decisions

- Gala is the initial organization. Each user belongs to one organization, but can have assignments in several of that organization's brands. Organization membership alone grants no operational access.
- Three role scopes define the access boundary: `organization`, `brand`, and `location`. Permissions define the actions allowed within that boundary.
- `user_roles` holds organization and brand assignments. Organization assignments apply across the assigned organization, including newly added brands. Brand assignments apply to one specified brand.
- `user_locations` holds one location role per user per store. A user can be a manager at Store A and an employee at Store B. Multiple simultaneous location roles at the same store are outside this design.
- Applicable role permissions combine. A location permission never extends to a different store solely because both stores belong to the same brand.
- Users have no `brand_id`; role assignments determine access. There is no separate brand-membership table in this design.
- Scope checks and composite foreign keys enforce which assignment table may reference each role. A missing brand ID alone never grants organization access.
- Composite foreign keys ensure the user and target brand belong to the same organization, and the target location belongs to that brand.
- Roles and permissions are shared reference data, changed only through reviewed migrations. Assigning existing roles to users is a separate, permission-controlled operation.
- An assigned role cannot be deleted. Its assignments must first be explicitly removed or reassigned through an authorized, audited process.
- Users, brands, and locations are normally deactivated rather than deleted. Assignment tables represent current access. The location-assignment write functions record their changes in an audit log; auditing other lifecycle changes remains pending.

## Access examples

These examples use the initial roles approved in the matrices below.

| Person | Assignment | Storage | Access boundary |
| --- | --- | --- | --- |
| GCP operations lead | `org_admin` for Gala | `user_roles`, organization scope, `brand_id = NULL` | All brands in Gala |
| Nancy | `brand_admin` for Brand A | `user_roles`, brand scope, Brand A's ID | All stores in Brand A |
| Bob | `location_manager` at Store A | `user_locations`, Store A's ID | Store A |
| Bob | `employee` at Store B | A second `user_locations` row | Store B |

Promotion from brand administrator to organization administrator adds an organization assignment. Remove the old brand assignment if the promotion is intended to replace it; otherwise it remains effective and must be considered during later demotion. The user's identity does not change.

## Approved initial permission matrix

**Review status:** Ali approved the permission matrices with two changes: Location Managers may invite users and assign or revoke Employee roles within locations they manage. The catalog contains four roles, eleven permissions, and thirty-two role-permission mappings. Scoped identity reads and location-assignment writes are implemented and tested. A catalog grant alone does not implement its feature: invitations, account deactivation, organization/brand assignment writes, and task workflows still need their respective implementation and tests.

### How to read the matrix

| Label | Meaning |
| --- | --- |
| Organization | The organization targeted by the caller's Organization Admin assignment |
| Brand | The specific brand targeted by the caller's Brand Admin assignment |
| Location | Each store where the caller holds the role named in that column |
| Self | The caller's own application profile |
| Denied | This role does not grant the action in the proposed initial release |

Permissions from applicable assignments combine. A denied cell is an absence of a grant, not an override of another applicable role. Organization scope does not automatically include every permission. For example, an Organization Admin with a separate Location Manager assignment can complete tasks at that location through the location role.

The proposed role keys are `org_admin`, `brand_admin`, `location_manager`, and `employee`. Corporate users who oversee one brand use the Brand Admin column; additional read-only corporate roles can be proposed separately if required.

| Action / permission key | Organization Admin | Brand Admin | Location Manager | Employee |
| --- | --- | --- | --- | --- |
| View locations — `locations.read` | Organization | Brand | Location | Location |
| View user profiles — `users.read` | Organization | Brand | Location | Self |
| Invite users — `users.invite` | Organization | Brand | Location | Denied |
| Deactivate application accounts — `users.deactivate` | Organization | Denied | Denied | Denied |
| View role assignments — `role_assignments.read` | Organization | Brand | Location | Own location assignment only |
| Grant, replace, or revoke role assignments — `role_assignments.manage` | Organization, subject to role-assignment matrix | Brand, subject to role-assignment matrix | Location, Employee assignments only; subject to role-assignment matrix | Denied |
| Create/edit recurring task definitions — `tasks.manage` | Organization | Brand | Location | Denied |
| View daily task instances — `task_instances.read` | Organization | Brand | Location | Location |
| Mark task instances complete — `task_instances.complete` | Denied | Denied | Location | Location |
| Reopen completed task instances — `task_instances.reopen` | Denied | Denied | Location | Denied |
| View completion reports — `reports.read` | Organization | Brand | Location | Denied |

### Resource and action boundaries

- **User profiles:** active users can read their own application profile, including during controlled onboarding before assignments exist. Other profile visibility requires the scoped `users.read` grant. A Location Manager sees users assigned to the same stores where the caller is a manager. A Brand Admin sees users with effective access to that brand; an organization assignment counts as such access. This does not expose other brands' assignments or allow editing global profile fields. Organization Admins may view users in their organization, including users awaiting assignment.
- **Assignment visibility:** profile visibility and assignment visibility are separate. A Brand Admin sees only brand and location assignments within the assigned brand, not another person's organization assignments. A Location Manager sees assignments at stores they manage. Each authenticated active user may inspect their own assignments for navigation and account display; this self-access does not grant visibility into other users' assignments.
- **Invitations:** the inviter needs `users.invite` and authority over every proposed role and target. Invite permission alone cannot grant a role. Inviting a person already in another organization cannot silently move their account or attach it to the inviter's organization.
- **Account deactivation:** this is organization-wide because `users.is_active` affects the whole account. Brand Admins remove authorized assignments within their brand instead of deactivating the person. Removing one assignment does not revoke access supplied by another applicable assignment, such as an organization role.
- **Task definitions:** `tasks.manage` means create and edit recurring definitions. A Location Manager may affect only stores where they hold that role; changing a shared definition that affects other stores requires authority over all affected targets. Hard deletion and historical changes are not implicitly granted by this permission.
- **Task completion:** the initial proposal allows employees to complete any task instance at an assigned store. Personally assigned tasks would require an additional assignee condition once that business rule and task model are defined. Reopening is a separate action, proposed for Location Managers only.
- **Task inspection:** reads necessary to create/edit a definition must obey the same scope checks. These permissions must be reconciled with Student B's task API before that feature is implemented.
- **Reports:** reporting uses the same organization, brand, and location boundaries. Historical access to inactive stores is a separate review item; `reports.read` alone does not settle that behavior.
- **Scope remains attached to each permission:** Bob's manager grant at Store A cannot authorize task edits at Store B, even if both stores share a brand.

Role definitions, permission definitions, and `role_permissions` are changed only through reviewed migrations. No application role receives runtime permission to edit that catalog. Authorized administrators can assign existing roles according to the next matrix.

## Approved initial role-assignment matrix

This matrix defines which existing role assignments an actor may grant, replace, or revoke. Both `role_assignments.manage` and the matching matrix entry are required. The targets must also satisfy the database organization, brand, location, and scope constraints.

| Actor's applicable role | Organization Admin assignment | Brand Admin assignment | Location Manager assignment | Employee assignment |
| --- | --- | --- | --- | --- |
| Organization Admin | Within assigned organization | Within assigned organization | Within assigned organization | Within assigned organization |
| Brand Admin | Denied | Denied | Stores within assigned brand | Stores within assigned brand |
| Location Manager | Denied | Denied | Denied | Stores where the actor holds a Location Manager role |
| Employee | Denied | Denied | Denied | Denied |

### Assignment safeguards

- Validate the existing assignment when revoking or replacing it, and the proposed assignment when granting or replacing it. An update must not move an otherwise allowed assignment into an unauthorized scope or target.
- A new permission does not take effect until the assignment change commits. Permission checks use the actor's existing authority, never the authority they are attempting to grant themselves.
- Changes to the actor's own assignments are denied through the ordinary assignment-management flow. Bootstrap and account-recovery procedures are separate and must be documented.
- Proposed protection, not yet implemented or approved: do not allow the last active Organization Admin to be deactivated or lose their final organization-admin assignment. Concurrent changes must not bypass this invariant.
- The role catalog has no numeric hierarchy. Authority comes from the explicit matrix, not a comparison such as “higher than my role.”
- Location-assignment writes record grants, replacements, and revocations with the actor, target, and old/new role IDs. Organization/brand assignment auditing remains pending.
- The matrix checks the assignment being changed, not every other role held by its recipient. For example, a Brand Admin may assign an Employee role at an authorized store to another user who also holds an Organization Admin role. This does not remove or reduce that user's organization permissions. Self-assignment changes remain denied.

### Example authorization decisions

| Request | Proposed result | Reason |
| --- | --- | --- |
| Bob, manager at Store A, edits an A-only task definition | Allow | Location Manager has `tasks.manage` at A |
| Bob, employee at Store B, edits a B-only task definition | Deny | Employee does not grant `tasks.manage` |
| Bob completes a task at Store B | Allow | Employee grants completion at B |
| Bob reopens a completed task at Store B | Deny | Employee does not grant reopening |
| Nancy, Brand A Admin, assigns a manager at an A store | Allow | Role-grant matrix permits that target |
| Nancy assigns Brand Admin or Organization Admin | Deny | Neither target role is permitted for Brand Admin |
| Nancy removes an Organization Admin's organization assignment | Deny | The organization assignment exceeds her authority |
| An Organization Admin with no location role completes a store task | Deny | Organization scope does not grant completion in this proposal |

## Entity relationship diagram

```mermaid
erDiagram
    direction TB

    organizations ||--o{ users : contains
    organizations ||--o{ brands : contains
    organizations ||--o{ user_roles : scopes
    organizations ||--o{ user_locations : scopes

    auth_users ||--o| users : identity

    brands ||--o{ locations : contains
    brands |o--o{ user_roles : optional_brand_target
    brands ||--o{ user_locations : scopes

    users ||--o{ user_roles : receives
    users ||--o{ user_locations : assigned_to

    locations ||--o{ user_locations : has

    roles ||--o{ user_roles : organization_or_brand_role
    roles ||--o{ user_locations : location_role
    roles ||--o{ role_permissions : grants
    permissions ||--o{ role_permissions : included_in

    auth_users {
        uuid id PK "external Supabase auth.users"
    }

    organizations {
        uuid id PK "default gen_random_uuid()"
        text name "not null"
        timestamptz created_at "not null, default now()"
        timestamptz updated_at "not null, maintained by trigger"
    }

    users {
        uuid id PK, FK "references auth.users.id, no default"
        uuid organization_id FK "not null"
        text email "not null, unique index on lower(email)"
        text full_name "not null"
        boolean is_active "not null, default true"
        timestamptz created_at "not null, default now()"
        timestamptz updated_at "not null, maintained by trigger"
    }

    brands {
        uuid id PK "default gen_random_uuid()"
        uuid organization_id FK "not null"
        text name "not null"
        text slug UK "not null, lowercase slug"
        boolean is_active "not null, default true"
        timestamptz created_at "not null, default now()"
        timestamptz updated_at "not null, maintained by trigger"
    }

    locations {
        uuid id PK "default gen_random_uuid()"
        uuid brand_id FK "not null"
        text store_number "optional"
        text name "not null"
        text address_line1 "optional"
        text city "optional"
        text state "optional"
        text postal_code "optional"
        text timezone "not null, intended IANA name"
        boolean is_active "not null, default true"
        timestamptz created_at "not null, default now()"
        timestamptz updated_at "not null, maintained by trigger"
    }

    roles {
        uuid id PK "default gen_random_uuid()"
        text key UK "not null"
        text name "not null"
        text description "optional"
        text scope "not null, organization or brand or location"
        timestamptz created_at "not null, default now()"
        timestamptz updated_at "not null, maintained by trigger"
    }

    permissions {
        uuid id PK "default gen_random_uuid()"
        text key UK "not null"
        text description "not null"
        timestamptz created_at "not null, default now()"
    }

    role_permissions {
        uuid role_id PK, FK "not null"
        uuid permission_id PK, FK "not null"
        timestamptz created_at "not null, default now()"
    }

    user_roles {
        uuid id PK "default gen_random_uuid()"
        uuid user_id FK "not null"
        uuid organization_id FK "not null"
        uuid role_id FK "not null"
        text role_scope FK "not null, organization or brand"
        uuid brand_id FK "null only for organization scope"
        timestamptz created_at "not null, default now()"
    }

    user_locations {
        uuid user_id PK, FK "not null"
        uuid location_id PK, FK "not null"
        uuid organization_id FK "not null"
        uuid brand_id FK "not null"
        uuid role_id FK "not null"
        text role_scope FK "not null, constrained to location"
        timestamptz created_at "not null, default now()"
        timestamptz updated_at "not null, maintained by trigger"
    }
```

## Database constraints

Mermaid displays individual columns and relationships. The following tables specify composite constraints that must be implemented in migrations.

### Keys and field conventions

- Entity tables and `user_roles` use UUID `id` primary keys with `gen_random_uuid()`, except `users.id`, which references the existing `auth.users.id` and has no default.
- `user_locations` uses primary key `(user_id, location_id)`.
- `role_permissions` uses primary key `(role_id, permission_id)`.
- All foreign-key columns are required except `user_roles.brand_id`, whose nullability is governed by assignment scope.
- Emails are required and unique through an index on `lower(email)`. Supabase Auth is authoritative for login email; the application copy must be synchronized.
- `brands.slug`, `roles.key`, and `permissions.key` are individually unique. Brand slugs use lowercase letters, numbers, and single separating hyphens.
- Location timezones must be valid supported IANA names. Validation implementation and timezone-change behavior are review items.
- `created_at` and `updated_at` default to `now()`. A shared `set_updated_at()` trigger maintains `updated_at` on every update to a table with that column.

### Composite unique constraints

| Table | Constraint | Purpose |
| --- | --- | --- |
| `users` | `UNIQUE (id, organization_id)` | Target for organization-consistent user references |
| `brands` | `UNIQUE (id, organization_id)` | Target for organization-consistent brand references |
| `brands` | `UNIQUE (organization_id, name)` | Prevent duplicate exact brand names within an organization |
| `locations` | `UNIQUE (id, brand_id)` | Target for brand-consistent location references |
| `locations` | `UNIQUE (brand_id, store_number)` | Prevent duplicate non-null store numbers within a brand; multiple unknown numbers remain allowed |
| `roles` | `UNIQUE (id, scope)` | Target for scope-consistent role references |
| `user_roles` | `UNIQUE NULLS NOT DISTINCT (user_id, role_id, brand_id)` | Prevent duplicate brand assignments and duplicate organization assignments with null brands |

`NULLS NOT DISTINCT` requires PostgreSQL 15 or later. Since each user belongs to exactly one organization, the user's ID also fixes the organization of an assignment.

### Composite foreign keys

| Referencing table | Referencing columns | Referenced columns |
| --- | --- | --- |
| `user_roles` | `(user_id, organization_id)` | `users(id, organization_id)` |
| `user_roles` | `(brand_id, organization_id)` | `brands(id, organization_id)` |
| `user_roles` | `(role_id, role_scope)` | `roles(id, scope)` |
| `user_locations` | `(user_id, organization_id)` | `users(id, organization_id)` |
| `user_locations` | `(brand_id, organization_id)` | `brands(id, organization_id)` |
| `user_locations` | `(location_id, brand_id)` | `locations(id, brand_id)` |
| `user_locations` | `(role_id, role_scope)` | `roles(id, scope)` |

Both assignment tables also directly reference `organizations(id)` through `organization_id`.

The nullable brand reference in `user_roles` uses `MATCH SIMPLE`. When `brand_id` is null, the scope check and separate organization/user constraints still apply. `MATCH FULL` would incorrectly reject a valid organization assignment with a null brand and non-null organization.

### Scope checks

```sql
-- roles
CHECK (scope IN ('organization', 'brand', 'location'))

-- user_roles
CHECK (role_scope IN ('organization', 'brand'))
CHECK (
    (role_scope = 'organization' AND brand_id IS NULL)
    OR
    (role_scope = 'brand' AND brand_id IS NOT NULL)
)

-- user_locations
CHECK (role_scope = 'location')
```

All scope columns are `NOT NULL`. `user_locations.role_scope` defaults to `location`; the check enforces the value even when a caller supplies it explicitly. Composite role/scope foreign keys ensure the assigned role matches the declared scope.

### Delete and update behavior

Deletion behavior belongs to each foreign key, as specified below. Normal application workflows deactivate users, brands, and locations; the cascade rules cover deliberate physical deletion by authorized administration.

| Referenced parent | Referencing child / foreign key | ON DELETE |
| --- | --- | --- |
| `auth.users` | `users.id` | `RESTRICT` |
| `organizations` | `users.organization_id` | `RESTRICT` |
| `organizations` | `brands.organization_id` | `RESTRICT` |
| `brands` | `locations.brand_id` | `RESTRICT` |
| `organizations` | `user_roles.organization_id` | `RESTRICT` |
| `organizations` | `user_locations.organization_id` | `RESTRICT` |
| `users` | `user_roles(user_id, organization_id)` | `CASCADE` |
| `users` | `user_locations(user_id, organization_id)` | `CASCADE` |
| `brands` | `user_roles(brand_id, organization_id)` | `RESTRICT` |
| `brands` | `user_locations(brand_id, organization_id)` | `RESTRICT` |
| `locations` | `user_locations(location_id, brand_id)` | `CASCADE` |
| `roles` | `user_roles(role_id, role_scope)` | **`RESTRICT`** |
| `roles` | `user_locations(role_id, role_scope)` | **`RESTRICT`** |
| `roles` | `role_permissions.role_id` | `CASCADE` |
| `permissions` | `role_permissions.permission_id` | `CASCADE` |

All foreign keys use `ON UPDATE RESTRICT`. Moving entities between organizations or brands requires a deliberate migration or dedicated workflow; foreign-key updates must not silently retarget assignments.

Deleting an assigned role fails and leaves its assignments and permission links intact. Deleting an unassigned role removes its `role_permissions` links. Deleting a permission removes its grants and is therefore a security-sensitive catalog migration requiring review.

The Auth foreign key prevents physical deletion of an Auth user while the application profile exists. Setting `public.users.is_active = false` denies application access; it does not itself disable Supabase authentication or revoke Auth sessions. Auth account deletion and data retention need a separate approved lifecycle procedure.

Deactivation preserves entity records, but it does not preserve overwritten or deleted assignments. The location-assignment audit log has no foreign keys, so its records survive deletion of referenced users, roles, locations, or assignments. It records changes through the authorized write functions; it does not automatically audit privileged direct SQL or cascades.

### Indexes

Each referencing foreign key needs a suitable index unless an existing primary-key or unique index already covers its leading columns. A composite index can satisfy this requirement; do not add redundant single-column indexes blindly.

| Table | Required index coverage |
| --- | --- |
| `users` | `(id)` through the primary key; `(organization_id)`; unique `lower(email)` |
| `brands` | `(organization_id)` covered by `UNIQUE (organization_id, name)` |
| `locations` | `(brand_id)` covered by `UNIQUE (brand_id, store_number)` |
| `user_roles` | `(user_id, organization_id)`, `(brand_id, organization_id)`, `(role_id, role_scope)`, `(organization_id)` |
| `user_locations` | `(user_id, organization_id)`, `(brand_id, organization_id)`, `(location_id, brand_id)`, `(role_id, role_scope)`, `(organization_id)` |
| `role_permissions` | `(role_id)` covered by the primary key; separate `(permission_id)` |

The composite unique constraints above create additional indexes. Final query plans should be checked using realistic seed data and the application database role.

## Authorization and RLS implementation

### Scope and action checks

- `current_user_brand_ids()` returns accessible brands based on organization, brand, and location assignments.
- `current_readable_location_ids()` returns stores covered by the caller's effective `locations.read` grants. Organization and brand assignments cover their respective active stores; location assignments cover only their assigned active stores.
- Brand-owned records use the accessible-brand boundary. Location-owned records additionally use the accessible-location boundary.
- A location assignment makes the brand discoverable but does not grant visibility of every store or every category of data in that brand.
- `users`, `organizations`, and organization-scoped `user_roles` require separate visibility policies because they cannot be filtered directly by a non-null `brand_id`.
- `current_user_permissions()` returns role, permission, scope, organization, brand, and location for the current active caller. Permissions must not be flattened into an unscoped list.
- The API checks action permissions against the resource's actual target, resolved from trusted data. The role-grant matrix must define which roles each administrator may assign and at which scope.
- SELECT, INSERT, UPDATE, and DELETE policies are designed separately. Updates validate existing rows with `USING` and proposed rows with `WITH CHECK`.
- No operation receives runtime grants until its authorization path is defined. Missing or inactive identity grants no access. Active users without assignments retain only the defined onboarding reads: their own profile, their organization, and the shared role/permission catalog.

### Trusted request context and helpers

- Required Express integration (pending): verify the JWT and set `app.user_id` transaction-locally on the same checked-out database connection used for permission checks and application queries.
- The runtime role does not own tables, has no `BYPASSRLS`, and cannot become the helper-owner role. RLS tests run as this runtime role.
- RLS helpers are `STABLE`, with controlled `SECURITY DEFINER` ownership, a fixed search path, fully qualified object names, and restricted execution grants.
- The helper owner reads authorization tables without recursively invoking their policies. `operations_hub_auth_reader` is a dedicated `NOLOGIN`, `BYPASSRLS` role with narrowly limited column-level SELECT privileges. Ownership and grants have been tested locally; hosted environment verification remains pending.
- Internal helpers accepting arbitrary user IDs are not exposed to the runtime role or browser. Public policy helpers derive the caller from verified request context.
- Any permissions view uses `security_invoker = true` unless a separately reviewed definer design is required. Views and helpers must not reintroduce policy recursion.
- The application still filters queries by the requested authorized brand and location; RLS provides a second boundary.
- Connection reuse must not leak identity between requests. Queries without context fail closed; transactions are committed or rolled back before release.

Application database credentials are backend-only. The database trusts Express to set the actor correctly; the session setting is not an independently authenticated credential.

### Location-assignment writes

The backend runtime can execute two functions in the private `identity_access` schema through its SQL connection. These are not browser-facing Supabase RPC endpoints:

| Function | Behavior |
| --- | --- |
| `set_location_assignment(target_user_id, target_location_id, target_role_id, request_id)` | Grants or replaces a location role; returns `granted`, `replaced`, or `unchanged` |
| `revoke_location_assignment(target_user_id, target_location_id, request_id)` | Removes an authorized existing assignment; returns `revoked`. Missing and forbidden assignments produce the same authorization error. |

Both functions use `SECURITY DEFINER`, owned by `operations_hub_assignment_writer`. This role cannot log in, does not own the tables, and cannot bypass RLS. The runtime cannot become this role or directly modify assignments or audit records. Internal authorization and target-resolution helpers are executable only by the roles that need them.

The functions check the role-assignment matrix, organization consistency, and the ban on self-changes. The writer's RLS policies also check assignment authority: UPDATE checks both the old role with `USING` and the proposed role with `WITH CHECK`. Grants and replacements require an active target user, brand, and location. Revocation can remove an inactive target's assignment if the caller still has effective authority. An unchanged assignment creates no audit event.

Each successful change inserts into `identity_access.assignment_audit_log` in the same transaction. An audit failure rolls back the assignment change. Records contain the actor, organization, target user, location, action, old/new role IDs, request ID, and occurrence time. The request ID supports correlation; it is not an idempotency key. Application roles cannot update or delete audit records. Privileged database owners can still modify them, so this is not a tamper-proof audit store. An application-facing, scoped audit-read path is not implemented yet.

### Concurrency contract for identity writers

Location-assignment functions call `identity_access.lock_assignment_organization()` before resolving targets or checking write authority. It takes a transaction-scoped advisory lock for the caller's organization and rechecks the caller's active identity after waiting. These writes require `READ COMMITTED`; stronger snapshot isolation levels are rejected so later checks can see changes committed while waiting.

**All future writers that can change this authorization decision must use the same organization lock before checks and writes.** This includes organization/brand assignment changes and user, brand, or location deactivation. The lock is cooperative: it does not automatically stop privileged SQL or functions that omit it. Catalog migrations and administrative repairs must be coordinated with active identity writes. Ordinary reads do not take this lock.

The current concurrency tests cover duplicate grants, a waiting manager losing authority, and a waiting caller being deactivated. Deactivation is simulated by a cooperating test transaction; the production deactivation workflow is still pending. This lock alone does not implement the proposed last-active-Organization-Admin safeguard.

### Activity and history

Inactive users must lose application access on subsequent requests even if their JWT has not expired. Role changes must be evaluated from current assignments rather than relying solely on stale JWT role claims.

Current permission resolution excludes brand grants for inactive brands and location grants for inactive brands or locations. Location discovery excludes inactive stores. Organization grants remain organization-scoped; each resource policy or write function must still enforce its target's activity rules. Authorized assignment cleanup is allowed as described above. Historical reporting access remains a separate company-review item, not an implemented reporting path.

## Lifecycle work outside the nine-table core

- **Invitations:** define authorized provisioning, acceptance, expiration, retries, and activation. An `invitations` table is proposed if tracking these states is required. New profiles without assignments require a controlled provisioning path.
- **Email synchronization:** Supabase Auth owns login email. Choose and test synchronization into `users.email`, including existing-user reconciliation and failed updates. Identity and assignments always use UUIDs.
- **Audit history:** location-assignment write auditing is implemented. Extend auditing to organization/brand assignment changes, deactivation, and permission-catalog changes; define scoped audit reads, retention, and the actor convention for system jobs.
- **Timezones:** validate supported IANA names and decide how location timezone changes affect future task generation and existing task instances.

These remaining workflows are not completed by the existing location-assignment migration.

## Required validation before handoff

The eight SQL verification files and disposable concurrency harness cover the implemented database paths, including 108 location-assignment write checks. Fresh-database testing applies all nine migrations transactionally as a non-superuser migration role. These checks do not replace real Supabase Auth, Express, pooler, or future feature integration tests. A separate migration README will document setup and test execution once the migration work is complete. The following is the full handoff checklist, including work still pending:

- Reject cross-organization assignments, wrong-brand locations, wrong-scope roles, and duplicate assignments, including organization assignments with null brand IDs.
- Reject deletion of a role referenced by either assignment table; allow deliberate deletion of an unassigned role and cleanup of its permission links.
- Verify an employee cannot access another store's operational records in the same brand without an applicable assignment.
- Verify a manager at Store A has only their assigned employee permissions at Store B.
- Verify brand administrators cannot access another brand and organization administrators cannot access another organization. Include a second synthetic organization in tests.
- Reject self-promotion and unauthorized broader grants according to the approved role-grant matrix. Check both old and new targets during replacements.
- Verify employees cannot reopen task instances, and broader admin roles do not gain completion permissions without an applicable location grant under the proposed matrix.
- Verify scoped profile access does not expose unrelated assignments; own-profile and own-assignment reads remain available to active users during onboarding.
- Verify invite permission alone cannot create unauthorized assignments and brand-level assignment removal does not deactivate a global account.
- Verify concurrent assignment revocation and account deactivation cannot remove the last active Organization Admin, if that proposed safeguard is approved.
- Verify role revocation and user deactivation remove access on subsequent requests.
- Verify context isolation after both commit and rollback, including concurrent requests through the intended pooler mode.
- Verify direct SQL as the runtime role remains subject to RLS, including unsafe attempted INSERT and UPDATE targets.
- Verify audit records survive assignment deletion and cannot be modified by the runtime role.

## Open questions for company review

1. The initial matrices are approved. Are additional roles or changes needed, including restrictions on assigning a location role to someone who also holds a broader role? Are both brand switching and consolidated reporting needed?
2. Should employees complete every task at an assigned store, or only tasks personally assigned to them? The current proposal allows store-level completion and reserves reopening for location managers.
3. Should Organization and Brand Admins be able to complete or reopen store tasks without an additional location role? The current proposal does not grant these actions through their broader roles.
4. Is the proposed user-directory visibility correct: own profile for employees, shared-store profiles for managers, and profiles with relevant access for brand administrators? Should Brand Admins ever grant or revoke other Brand Admin assignments?
5. Is the proposed inactive brand/location behavior correct, and which roles may read historical records? Should any broader role be protected from account deactivation by another administrator?
6. How should invitations, existing Auth accounts, email synchronization, and first-administrator provisioning work? Confirm the proposed protection against removing the last active Organization Admin.
7. Which timezone names are accepted, and how should timezone changes affect checklist scheduling?
8. What audit retention and account-deletion procedures does the company require?

Keep approved matrix changes synchronized with the catalog migrations, authorization rules, and tests. Before handoff, complete the pending workflows and integration checks and obtain review of the security-sensitive SQL. The diagram alone is not evidence that constraints or policies have been implemented or tested.
