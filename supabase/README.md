# Identity database migrations and tests

This directory contains the versioned PostgreSQL identity schema and access controls for Operations Hub. The business rules and diagram are in [Database Design](../docs/db-design.md).

## Current scope

Ten migrations implement the nine core identity tables, a private assignment audit table, the approved permission catalog, scoped read policies, and controlled role-assignment writes at organization, brand, and location scope. All ten migrations, nine SQL verification files, and the concurrency checks have passed in isolated local testing. Local Supabase verification has also passed.

Account lifecycle writes, invitations/provisioning, email synchronization, first-admin/recovery procedures, scoped audit reads, and Express integration remain unfinished. The lifecycle and audit decisions awaiting company confirmation are listed in the design document. The shared Supabase project has not received these migrations yet.

## Directory layout

| Path | Purpose |
| --- | --- |
| `config.toml` | Local Supabase configuration; PostgreSQL 17 |
| `migrations/` | Ordered schema, catalog, and authorization changes |
| `tests/*.sql` | Self-contained SQL verification scripts |
| `tests/location_assignment_concurrency.py` | Disposable-database regression and concurrent-write tests for all assignment scopes |
| `snippets/` | Ignored local SQL Editor scratch files; not migration or test source |

## Local setup

Run commands from the repository root. Prerequisites are Node.js 22+, npm, and a running Docker-compatible engine. The Supabase CLI is a repository development dependency. Python 3 is needed for the concurrency harness; `psql` is needed only for terminal-based SQL verification.

```bash
npm ci
npx supabase start
npx supabase migration up --local
```

Starting a fresh local stack can already apply the migrations. `migration up --local` applies any remaining pending versions. It does not deploy to the hosted project.

Use `npx supabase status` to find your local Studio and database connection details. Keep keys and connection credentials out of commits, screenshots, and review descriptions. Local setup does not require linking to the shared project.

## Migration order

The CLI applies files in timestamp order. Do not apply only the final file to an empty database.

| File prefix | Change |
| --- | --- |
| `20261016061720` | Core tables, constraints, indexes, timestamp triggers, RLS enabled |
| `20261016201417` | Four roles, eleven permissions, thirty-two role-permission mappings |
| `20261016204609` | Restricted database roles and active-caller helpers |
| `20261016214938` | Scoped effective-permission helper |
| `20261016225651` | Location read policies |
| `20261016232134` | User-profile read policies |
| `20261017015123` | Assignment read policies |
| `20261017212605` | Organization, brand, and catalog read policies |
| `20261017224805` | Audited location-assignment writes and organization locking |
| `20261018093323` | Audited organization/brand assignment writes and expanded audit targets |

Create future changes with `npx supabase migration new descriptive_name`. Keep applied/shared history stable and make subsequent changes in a new migration. The reference catalog is not demo data: it does not create the first administrator or operational users.

### Transaction requirements

Each complete migration must execute in a transaction. Ownership transfers temporarily grant role membership and schema privileges; failure must roll back those grants together with the schema changes. Use the Supabase CLI for normal migration tracking. The disposable harness explicitly wraps each migration in `BEGIN`/`COMMIT`.

For manual execution in a disposable database, use `psql --single-transaction -v ON_ERROR_STOP=1 -f <file>` with that database's connection. Plain nontransactional `psql -f` may leave partial changes. Manual execution does not maintain Supabase migration history. `SET ROLE`/`RESET ROLE` and PL/pgSQL `BEGIN ... END` blocks do not replace a migration transaction.

`npx supabase db reset --local` rebuilds the local database and discards its current application data. Use it only when intentionally rebuilding disposable local state, not as the routine next step after editing a file. There are no automatic down migrations; shared-environment recovery requires a reviewed plan.

## Run SQL verification on local Supabase

Apply the migrations first. Use a fresh local connection as `postgres`, without an existing `app.user_id` setting or manually granted runtime-role membership. The scripts create fixtures as the migration role, then switch to restricted roles to exercise application behavior. Successful queries as `postgres` alone do not prove RLS works.

**Studio:** open the local SQL Editor, select the `postgres` role, paste one complete verification file, and run it. Do not run only selected fragments. If a script fails, stop and roll back any open transaction before investigating or retrying.

**Terminal:** set `LOCAL_DATABASE_URL` in your shell to the database URL from your local Supabase instance. Then run one file:

```bash
psql "$LOCAL_DATABASE_URL" -X -v ON_ERROR_STOP=1 \
  -f supabase/tests/user_role_write_verification.sql
```

Or run every SQL file with a separate connection, stopping at the first failure:

```bash
for test_file in supabase/tests/*.sql; do
  psql "$LOCAL_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f "$test_file" || break
done
```

The scripts manage their own transactions and roll back fixtures. Do not add `--single-transaction` around these tests: the identity-access script deliberately tests both COMMIT and ROLLBACK context cleanup, committing no application fixtures. Run them locally, not against the shared project.

Coverage includes schema constraints, exact catalog mappings, role attributes and grants, identity-context cleanup, scoped reads, authorized writes, audit records, and rollback after injected audit failures. Location writes check both the existing and proposed role during replacement. Organization/brand writes check null-safe duplicate detection and preserve unrelated assignments.

## Fresh-database and concurrency verification

```bash
python3 supabase/tests/location_assignment_concurrency.py
```

Despite its original filename, this harness now tests all assignment scopes. It requires Docker and an already-downloaded image, defaulting to `public.ecr.aws/supabase/postgres:17.11.0.004`. Use `--image <compatible-local-image>` to override it. It uses Python's standard library and does not download images automatically.

The harness:

1. Creates an isolated disposable PostgreSQL container with no published ports, host data mounts, or external network.
2. Applies all migrations transactionally as a non-superuser `postgres` role.
3. Runs every SQL verification file in `tests/`.
4. Checks duplicate grants, authority revoked while a writer waits, caller deactivation while waiting, and rejection of unsupported transaction isolation levels.
5. Removes the disposable container on normal completion or handled failure.

It does not connect to your local project database or shared Supabase project. Its minimal synthetic `auth.users` table supports database-only tests; it does not test real Supabase Auth, Express token verification, or connection-pool behavior. Those require separate integration tests.

CI runs this harness on every pull request in the **Database (migrations + RLS tests)** job (`.github/workflows/ci.yml`). The job pulls the same image tag from Docker Hub (`supabase/postgres`), because anonymous ECR Public pulls hit data limits on shared runners, then passes it with `--image`. If you change the default image tag in the harness, update `POSTGRES_IMAGE` in the workflow too.

## Backend integration contract

- Express must verify the Supabase access token and derive the actor from the verified identity, never a client-supplied user ID.
- Protected operations use a transaction on one checked-out SQL connection, with transaction-local `app.user_id` and the restricted `operations_hub_runtime` role. Commit or roll back before releasing the connection.
- The runtime role is `NOLOGIN`; provisioning a backend login with appropriately restricted role membership is separate integration work. Do not use the migration owner or a bypass-RLS role for ordinary application queries.
- Read helpers resolve current assignments and activity state. API checks must retain the permission's organization, brand, and location scope.
- Assignment writes call `identity_access.set_location_assignment`, `revoke_location_assignment`, `grant_user_role`, or `revoke_user_role`. These are private-schema SQL entry points, not browser-facing Supabase RPC endpoints. `anon` and `authenticated` do not receive access to them.
- Write entry points run as a restricted, non-owner writer without RLS bypass. The separate authorization-reader role has narrowly granted SELECT privileges and RLS bypass to prevent recursive policy evaluation; runtime cannot become either role.
- Writes require `READ COMMITTED` and acquire the shared organization advisory lock. Future deactivation and other authorization-changing writers must follow the same lock contract. Privileged SQL does not automatically participate.
- Actual assignment changes and audit records are atomic. Duplicate authorized grants are no-ops. Request IDs correlate events; they do not provide general request idempotency.
- The audit table has no application-facing read path yet. Application roles cannot modify or delete audit history, but privileged database owners can. It is not a tamper-proof store.

## Review and shared deployment

Before opening the PR, review the migration diff, run relevant tests, and record results and remaining work. Keep unfinished lifecycle files and real credentials out of the change. Confirm that documentation distinguishes approved rules from proposals awaiting company answers.

Review and merge precede applying these changes to the shared Supabase project. Coordinate the target project, current schema/history, PostgreSQL version, recovery plan, and team timing before deployment. Passing disposable tests is not authorization to push schema changes to the shared project. Verify hosted role grants and application behavior separately afterward.

## Deploying to the shared project

`.github/workflows/deploy-database.yml` applies migrations to the shared Supabase project. Merging a migration into `main` is therefore the deployment decision, so the coordination above happens during PR review.

- **Trigger:** a push to `main` that changes `supabase/migrations/**`. Other merges do not deploy.
- **Verify first:** the workflow re-runs the disposable-database harness on the exact commit. The deploy job runs only if it passes.
- **Deploy:** `supabase db push` lists the pending migrations, then applies them and records them in the project's migration history. Migrations already applied are skipped. A remote history that does not match `migrations/` stops the push before anything is applied.
- **No overlap:** deploys queue one after another and are never cancelled partway through.
- **Not included:** seed data, vault secrets, `supabase/setup/` scripts, and roll-backs. There are no down migrations; fix forward with a new migration.

### One-time setup (repository admin)

1. Create the `supabase-shared` environment under **Settings → Environments**. The first workflow run also creates it if it does not exist. Set **Deployment branches** to `main` only. The workflow already refuses other branches, and this setting also keeps the secret away from them. Optionally add required reviewers so each deploy waits for approval.
2. Add an environment secret `SUPABASE_DB_URL`, using the **Session pooler** connection string from the Supabase dashboard (**Connect → Session pooler**, port 5432) with the database password filled in and percent-encoded. GitHub runners are IPv4-only, so the direct connection does not work, and the transaction pooler (port 6543) does not support migrations.
3. Before the first real deploy, run **Actions → Deploy database → Run workflow** with *dry run* checked. Confirm the listed migrations match what the shared project is missing. If the project already has tables or migration history created outside this folder, resolve that first.

To deploy manually, for example after fixing the secret, run the workflow with *dry run* unchecked.
