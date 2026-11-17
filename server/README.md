# Operations Hub — Backend

Express 5 + TypeScript API with Supabase authentication and PostgreSQL-backed identity access. `/api/me` reads the authenticated user's application profile and scoped access. The protected `/api/task-instances` endpoints list, complete, and reopen PostgreSQL task instances. The prototype `/api/tasks` routes still use an in-memory store; restarting the server resets that prototype data. Those prototype routes, including the demo reset route, remain public.

## Local setup

Run commands from the repository root unless indicated otherwise.

1. Install dependencies with `npm install`.
2. Start local Supabase with `npx supabase start` and apply all pending local migrations with `npx supabase migration up --local`, following [the database setup guide](../supabase/README.md).
3. As a database administrator, run [create_backend_login.sql](../supabase/setup/create_backend_login.sql) after the migrations. This is a one-time provisioning script: it creates `operations_hub_api` and grants permission to switch to `operations_hub_runtime`. It is not safe to rerun unchanged if the login already exists. Set the login's password separately; never commit it. Reprovision the login if your local database is recreated.
4. Copy `server/.env.example` to `server/.env` if you do not already have that file. Fill in your local values:

```dotenv
PORT=4000
CORS_ORIGIN=http://localhost:3000
SUPABASE_URL=http://127.0.0.1:54321
SUPABASE_PUBLISHABLE_KEY=your-supabase-publishable-key
DATABASE_URL=postgresql://operations_hub_api:your-db-password@127.0.0.1:54322/postgres
```

Get the API URL and publishable key from your local Supabase setup (`npx supabase status`). The database password must match the password set for `operations_hub_api`; editing `.env` does not change the database password. URL-encode special characters in the connection-string password. Keep `.env` local and use placeholders in `.env.example`. Never put `DATABASE_URL` in frontend configuration.

```bash
npm run dev:server
```

The workspace command runs the backend from `server/`, where startup loads `.env` before creating the auth client and database pool. `CORS_ORIGIN` supports comma-separated frontend origins.

```bash
npm run build:server
npm run start:server
curl http://localhost:4000/api/health
```

The health endpoint returns `{"status":"ok"}`; it does not check Supabase or database connectivity.

## Authentication and application access

Clients sign in through Supabase Auth and obtain an access token. There is no separate backend password-login endpoint. Send the access token on protected requests:

```bash
curl http://localhost:4000/api/me \
  -H "Authorization: Bearer <access-token>"
```

The auth middleware verifies the token with Supabase and stores the verified user ID in `res.locals.actorId`. A Supabase Auth account alone does not grant application access: a matching active `public.users` profile is required, and database role/location assignments determine scoped permissions. An active profile with no assignments may receive empty permissions, brands, or locations arrays.

### GET /api/me

No request body or user-ID parameter is needed. The response uses camelCase:

```json
{
  "user": {
    "id": "<user-uuid>",
    "email": "employee@example.com",
    "fullName": "Example Employee",
    "organizationId": "<organization-uuid>"
  },
  "permissions": [
    {
      "permission": "locations.read",
      "role": "employee",
      "scope": "location",
      "organizationId": "<organization-uuid>",
      "brandId": "<brand-uuid>",
      "locationId": "<location-uuid>"
    }
  ],
  "brands": [{ "id": "<brand-uuid>", "name": "Example Brand", "slug": "example-brand" }],
  "locations": [
    {
      "id": "<location-uuid>",
      "brandId": "<brand-uuid>",
      "name": "Example Location",
      "storeNumber": null,
      "timezone": "America/Los_Angeles"
    }
  ]
}
```

The example illustrates the shape, not seeded data. Permission `brandId` and `locationId` can be null depending on scope; `storeNumber` can also be null. Permission entries retain their role and scope, so the same permission may appear more than once. Brands and locations are filtered by database row-level security (RLS). The frontend must not treat these lists as a replacement for authorization on subsequent backend operations.

| Status | Meaning |
| --- | --- |
| 200 | Active application profile and scoped access returned. |
| 401 | Missing/malformed bearer header, no authenticated user, or Supabase reports an invalid/expired token with status 401/403. |
| 403 | No visible active application profile. Error code: `PROFILE_NOT_FOUND`. |
| 503 | Supabase returns an authentication error other than 401/403. |
| 500 | Unexpected failure, including database errors. |

Errors use `{"error":{"message":"..."}}`. The profile error also includes a code:

```json
{"error":{"code":"PROFILE_NOT_FOUND","message":"No active application profile"}}
```

Clients should obtain a fresh token or prompt sign-in for 401, show an application-access message for 403, and offer retry for service failures. Never interpret an authentication-service failure as a successful login.

## Task-instance listing

### GET /api/task-instances

Lists existing database-backed task instances for one location and calendar day.
Send a bearer access token and both query parameters:

| Parameter | Requirement |
| --- | --- |
| `locationId` | One UUID string identifying the location. |
| `date` | One real calendar date in exactly `YYYY-MM-DD` format, between 2000 and 2199. Missing, repeated, malformed, and impossible dates are rejected. |

The date means the selected store's calendar day and filters `scheduled_day`;
it is not converted from the viewer's or server's timezone. There is no implicit
“today” default. Send no request body; the controller takes filters only from the
query string. Normal application JSON parsing and size limits still apply if a
body is sent. Date ranges, pagination, and completion-state filters are not
implemented; extra query parameters do not add filters.

```bash
curl -i --get 'http://localhost:4000/api/task-instances' \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  --data-urlencode "locationId=$LOCATION_ID" \
  --data-urlencode 'date=2026-11-13'
```

Use an existing location UUID and valid access token in the shell variables.
The controller checks `task_instances.read` for the requested location through
`current_location_ids_with`, then queries through `withUserTransaction` with RLS
still enforced. Directory access (`locations.read`) alone is insufficient.
Employees and Location Managers have access at assigned locations; Brand and
Organization Admins have read access within their respective scopes under the
[approved matrix](../docs/db-design.md#approved-initial-permission-matrix).

Success returns `200` with an object containing a task array:

```json
{
  "tasks": [
    {
      "id": "<instance-uuid>",
      "name": "Check fridge temperature",
      "description": "Record the current temperature.",
      "category": "Opening",
      "scheduledAt": "2026-11-13T18:00:00.000Z",
      "scheduledDay": "2026-11-13",
      "isAllDay": false,
      "timezone": "America/Los_Angeles",
      "dueTime": null,
      "completedAt": null,
      "completedBy": null,
      "recordedValue": null,
      "notes": null,
      "numericUnit": "C",
      "numericMin": -30,
      "numericMax": 50
    }
  ]
}
```

The example shows the response shape, not seeded data. Results are ordered by
`scheduled_at` ascending, then UUID `id` ascending to break ties. Multiple daily
occurrences have separate IDs and scheduled instants. `scheduledAt` is an ISO
UTC timestamp, not an automatic visibility cutoff or deadline; display it using
`timezone`. `scheduledDay` remains a date-only string. `isAllDay` identifies
all-day occurrences; their midnight anchor is not a timed appointment.

Names, instructions, category, timezone, and numeric configuration come from
instance snapshots. `dueTime` is a nullable local time string; timed instances
use `scheduledAt` to distinguish occurrences. `completedAt` is an ISO timestamp
or `null`, and `completedBy` is a user UUID or `null`. Readings and bounds are
numbers or `null`, with the same JavaScript precision limits as completion
responses. Notes and units are nullable strings. Render notes as plain text.

An accessible location with no matching tasks returns `200` with
`{"tasks":[]}`. A denied or nonexistent location returns the same generic `403`
without revealing its existence. Permission checking and task reading are
separate statements: if access is revoked between them, RLS can filter out the
rows, resulting in an empty list rather than a second explicit 403 check.

| Status | Meaning / error code |
| --- | --- |
| 200 | Task list, possibly empty. |
| 400 | `INVALID_LOCATION_ID` or `INVALID_DATE`; malformed JSON also returns 400 if supplied. |
| 401 | Missing, malformed, invalid, or expired authentication. |
| 403 | `TASK_OPERATION_FORBIDDEN`: location read permission is absent, including inactive/missing identity or inactive/missing location/brand. |
| 503 | Authentication service returns an error other than an invalid-token 401/403. |
| 500 | Unexpected failure, including database errors. |

This endpoint returns current instance state, not audit history, and does not
generate missing instances. Dedicated endpoint tests and real-database HTTP
verification of this list contract remain pending teammate work.

## Task-instance completion and reopening

These endpoints operate on existing PostgreSQL task instances using UUIDs, not
on the numeric IDs of the prototype `/api/tasks` API. Apply migrations through
`20261110000000_create_task_completion_functions.sql` before using them.
Instance creation and recurrence generation are separate work.

Both endpoints require `Authorization: Bearer <access-token>`. The actor comes
from the verified token, never from request input. An active application profile,
active brand/location, and the appropriate scoped permission are required:

| Operation | Permission | Initial role grants |
| --- | --- | --- |
| Complete | `task_instances.complete` | Employee or Location Manager at the assigned location |
| Reopen | `task_instances.reopen` | Location Manager at the assigned location |

Organization/Brand Admin roles alone grant neither action. Applicable location
roles can grant these actions independently; see the
[approved permission matrix](../docs/db-design.md#approved-initial-permission-matrix).

### POST /api/task-instances/:id/complete

`:id` must be an instance UUID. No body or `{}` completes without a reading or
notes. A supplied body must use `Content-Type: application/json` and contain
only these optional fields:

| Field | Accepted value |
| --- | --- |
| `recordedValue` | Finite JSON number or `null`; numeric strings are rejected. The database enforces the instance's inclusive snapshotted bounds. |
| `notes` | String of at most 2,000 Unicode code points or `null`. Blank notes are normalized to `null` by the database; meaningful notes retain formatting. |

Omitted fields become `null`; zero remains a valid reading. Unknown fields,
arrays, and explicit JSON `null` bodies are rejected. Notes are plain text and
must be rendered as text by clients.

```bash
curl -i -X POST "http://localhost:4000/api/task-instances/$INSTANCE_ID/complete" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"recordedValue":4.5,"notes":"Fridge checked."}'
```

Use an existing instance UUID and a valid token in those shell variables.
Success returns `200` after the transaction commits:

```json
{
  "id": "<instance-uuid>",
  "completedAt": "2026-11-13T05:42:36.262Z",
  "completedBy": "<authenticated-user-uuid>",
  "recordedValue": 4.5,
  "notes": "Fridge checked."
}
```

`recordedValue` is a JSON number or `null`. The response mapper converts PostgreSQL
`numeric` strings to JavaScript numbers; exact decimal precision is not preserved.
This contract assumes readings fit JavaScript number precision and is not an
exact-decimal financial calculation interface.

### POST /api/task-instances/:id/reopen

Accepts no body or an empty JSON object `{}`. Other parsed bodies or fields are
rejected. A supplied body must use `Content-Type: application/json`.

```bash
curl -i -X POST "http://localhost:4000/api/task-instances/$INSTANCE_ID/reopen" \
  -H "Authorization: Bearer $ACCESS_TOKEN"
```

Success returns `200` with the same response shape: `id` identifies the instance,
and `completedAt`, `completedBy`, `recordedValue`, and `notes` are all `null`.
Reopening changes the same instance; it does not create the next recurring task.
Previous completion events, readings, and notes remain in the audit history.

### Errors and transaction behavior

| Status | Meaning / error code |
| --- | --- |
| 400 | Invalid UUID (`INVALID_INSTANCE_ID`), body (`INVALID_BODY`), reading type (`INVALID_RECORDED_VALUE`), notes (`INVALID_NOTES`), or database input/bounds rejection (`INVALID_TASK_INPUT`). Malformed JSON also returns 400. |
| 401 | Missing, malformed, invalid, or expired authentication. |
| 403 | `TASK_OPERATION_FORBIDDEN`: inactive/missing application identity or unauthorized target. Hidden and nonexistent instance IDs receive the same generic error. |
| 409 | `TASK_STATE_CONFLICT`: already completed for complete, or already open for reopen. |
| 413 | Request body exceeds the application's 1 MB JSON parser limit. |
| 415 | `UNSUPPORTED_MEDIA_TYPE`: a body is supplied without the supported JSON content type. |
| 503 | Authentication service returns an error other than an invalid-token 401/403. |
| 500 | Unexpected failure, including database connection or transaction-configuration errors. |

Controller errors use this shape; parser/authentication errors may omit `code`:

```json
{
  "error": {
    "code": "TASK_STATE_CONFLICT",
    "message": "Task is already in the requested state."
  }
}
```

The controllers call the SQL functions through `withUserTransaction`. State and
audit events commit together; database exceptions roll back before error responses
are sent. Rejected state transitions do not add events. Requests are not
request-ID-idempotent: after a network timeout, reconcile state before retrying.
Use the location/date list endpoint above to reconcile current instance state.

Task writes require READ COMMITTED. The transaction helper uses plain `BEGIN`,
so keep the connection's default isolation at READ COMMITTED. Other isolation
levels fail as server errors. The SQL functions serialize writes within an
organization and recheck permissions after waiting; see the
[database completion contract](../docs/task-completion.md) for locking and audit details.
No deadline, future-date, or historical cutoff is enforced by these operations.

## Route and controller responsibilities

`app.ts` mounts the `/api/me` and `/api/task-instances` routers when both the pool and authentication middleware are provided. `src/routes/me.routes.ts` connects the GET route to `requireAuth`, then to the handler returned by `createGetMeController(pool)`.

`src/controller/me.controller.ts` owns the profile/access queries, response mapping, and the 403 response for a missing active profile. It receives the pool through its factory and reads the verified actor ID from `res.locals.actorId`; it does not create connections or authenticate tokens itself. Database operations run through `withUserTransaction`, and unexpected errors propagate to the application error handler.

`src/routes/task-instances.routes.ts` creates the list/completion/reopening controllers and connects authentication and handlers; POST routes also check JSON content types. `src/controller/task-instances.controller.ts` validates inputs and maps responses. Listing checks scoped read access and performs an RLS-protected query. Writes call controlled SQL functions and translate recognized SQL errors after rollback; unexpected errors propagate to the application error handler.

When adding a protected route, attach authentication before the controller and pass dependencies into the controller factory. Keep URL/middleware wiring in the router and request-handling behavior in the controller. The existing Tasks routes have not yet been moved into controllers.

## Writing protected database operations

Use the helpers in `src/db/transaction.ts` with an actor ID supplied by verified authentication:

- `queryAsUser(pool, userId, query, values)` runs one parameterized query.
- `withUserTransaction(pool, userId, work)` runs multiple queries on the callback's database client in one transaction.

Both borrow a pooled connection, begin a transaction, switch locally to `operations_hub_runtime`, and set `app.user_id` transaction-locally. They commit on success, roll back on failure, and release the connection. A connection is discarded if rollback fails. The pool permits up to five connections per pool instance; this is not a five-user login limit.

SQL text must be controlled by backend code. Pass request values separately using `$1`, `$2`, etc.; never concatenate request input into SQL. Do not accept the actor ID from a request body or query parameter. Inside `work`, use only the supplied client, await all queries, and do not issue transaction-control statements or change the role/actor context.

The helpers currently use plain `BEGIN`: they are general read/write transactions, not read-only transactions. Permissions and RLS still apply. Multiple statements share an identity and connection, but the default READ COMMITTED isolation does not guarantee one unchanged snapshot across all statements.

`index.ts` creates the dependencies after loading configuration and calls `createApp({ pool, requireAuth })`. Tests can inject dependencies. Calling `createApp()` without them omits both `/api/me` and `/api/task-instances`; it does not mount unprotected versions of those routes.

## Validation

Run these checks from the repository root:

```bash
npm run typecheck:server
npm run build:server
```

## Tests

```bash
npm run test:server       # from the repo root (CI runs this on every pull request)
```

API integration tests live in `test/` and use [Vitest](https://vitest.dev) + [Supertest](https://github.com/ladjs/supertest) against `createApp()` — no separately started backend is needed; Supertest opens a temporary local listener. The in-memory store is reset before each test. Case IDs in test names (e.g. `API-04`) refer to `docs/QA.md`. The current suite covers the Tasks API and health/unknown routes; it does not exercise `/api/me` or the database-backed task-instance endpoints. Manual verification results belong in the PR description; these endpoints still need dedicated automated HTTP coverage.

## Prototype task model

```ts
{
  id: number
  label: string                       // description
  cat: 'Opening' | 'Midday' | 'Closing'
  done: boolean
  date: string                        // YYYY-MM-DD
  time: string                        // HH:mm (24h) or ""
  attachments: string[]
  recurrence: 'none' | 'daily' | 'weekly'
  recurrenceDays: number[]            // 0=Sun … 6=Sat, weekly only
}
```

## Prototype task and health endpoints

| Method | Path                | Description                                                   |
| ------ | ------------------- | ------------------------------------------------------------- |
| GET    | `/api/health`       | Health check                                                  |
| GET    | `/api/tasks`        | List tasks. Query filters: `date`, `from`, `to`, `cat`, `done` |
| GET    | `/api/tasks/:id`    | Get one task                                                  |
| POST   | `/api/tasks`        | Create. Required: `label`, `cat`, `date`                       |
| PATCH  | `/api/tasks/:id`    | Partial update, e.g. `{ "done": true }`                        |
| DELETE | `/api/tasks/:id`    | Delete (204)                                                  |
| POST   | `/api/tasks/reset`  | Restore the seed data (demo helper)                           |

Task validation/not-found errors look like `{ "error": { "message": "...", "details": ["..."] } }` with status 400 / 404.

Examples:

```bash
curl http://localhost:4000/api/tasks?done=false
curl -X POST http://localhost:4000/api/tasks -H "Content-Type: application/json" \
  -d '{"label":"Restock napkins","cat":"Closing","date":"2026-08-19"}'
curl -X PATCH http://localhost:4000/api/tasks/3 -H "Content-Type: application/json" -d '{"done":true}'
curl -X DELETE http://localhost:4000/api/tasks/3
```

## Migrating task storage to the database

Prototype task data access goes through `src/store/task.store.ts`. Database-backed task instances use a separate UUID-based contract and controlled SQL writes. Migrating prototype CRUD/list routes requires deliberate API, authentication, validation, and frontend changes; replacing the store alone is not sufficient.

```
src/
  index.ts                  starts the server
  app.ts                    express app, CORS, JSON, error handling
  routes/tasks.routes.ts    /api/tasks endpoints
  routes/me.routes.ts       /api/me routing and authentication wiring
  routes/task-instances.routes.ts  protected listing/completion/reopening routes
  controller/me.controller.ts  /api/me queries and response handling
  controller/task-instances.controller.ts  task reads/writes, validation, responses
  validation/task.ts        request body validation
  store/task.store.ts       in-memory repository
  data/tasks.seed.ts        mock tasks from the design
  types/task.ts             Task types
  types/me.ts               /api/me row types
  types/task-instance.ts    task-instance state and list row types
  auth/bearer-token.ts      bearer-token parsing and Supabase auth client
  auth/require-auth.ts      token verification middleware
  db/pool.ts                PostgreSQL connection pool
  db/transaction.ts         user-scoped transaction helpers
```
