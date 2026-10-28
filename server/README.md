# Operations Hub — Backend

Express 5 + TypeScript API with Supabase authentication and PostgreSQL-backed identity access. `/api/me` reads the authenticated user's application profile and scoped access. Tasks still use an in-memory store; restarting the server resets task data. The existing task routes, including the demo reset route, are currently public.

## Local setup

Run commands from the repository root unless indicated otherwise.

1. Install dependencies with `npm install`.
2. Start local Supabase with `npx supabase start` and apply the identity migrations following [the database setup guide](../supabase/README.md).
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

## Writing protected database operations

Use the helpers in `src/db/transaction.ts` with an actor ID supplied by verified authentication:

- `queryAsUser(pool, userId, query, values)` runs one parameterized query.
- `withUserTransaction(pool, userId, work)` runs multiple queries on the callback's database client in one transaction.

Both borrow a pooled connection, begin a transaction, switch locally to `operations_hub_runtime`, and set `app.user_id` transaction-locally. They commit on success, roll back on failure, and release the connection. A connection is discarded if rollback fails. The pool permits up to five connections per pool instance; this is not a five-user login limit.

SQL text must be controlled by backend code. Pass request values separately using `$1`, `$2`, etc.; never concatenate request input into SQL. Do not accept the actor ID from a request body or query parameter. Inside `work`, use only the supplied client, await all queries, and do not issue transaction-control statements or change the role/actor context.

The helpers currently use plain `BEGIN`: they are general read/write transactions, not read-only transactions. Permissions and RLS still apply. Multiple statements share an identity and connection, but the default READ COMMITTED isolation does not guarantee one unchanged snapshot across all statements.

`index.ts` creates the dependencies after loading configuration and calls `createApp({ pool, requireAuth })`. Tests can inject dependencies. Calling `createApp()` without them omits `/api/me`; it does not mount an unprotected version of that route.

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

API integration tests live in `test/` and use [Vitest](https://vitest.dev) + [Supertest](https://github.com/ladjs/supertest) against `createApp()` — no server process or port needed. The in-memory store is reset before each test. Case IDs in test names (e.g. `API-04`) refer to `docs/QA.md`.

## Task model

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

## Task and health endpoints

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

Task data access goes through `src/store/task.store.ts`. Replace that file with a DB-backed version exposing the same functions (`listTasks`, `getTask`, `createTask`, `updateTask`, `deleteTask`) — routes and validation stay the same.

```
src/
  index.ts                  starts the server
  app.ts                    express app, CORS, JSON, error handling
  routes/tasks.routes.ts    /api/tasks endpoints
  routes/me.routes.ts       /api/me endpoint
  validation/task.ts        request body validation
  store/task.store.ts       in-memory repository
  data/tasks.seed.ts        mock tasks from the design
  types/task.ts             Task types
  types/me.ts               /api/me row types
  auth/bearer-token.ts      bearer-token parsing and Supabase auth client
  auth/require-auth.ts      token verification middleware
  db/pool.ts                PostgreSQL connection pool
  db/transaction.ts         user-scoped transaction helpers
```
