# End-to-end tests (Playwright)

Browser tests that drive the real Next.js client against the real Express tasks API,
the same way a user would: sign in, navigate, and create / edit / complete / delete tasks.

Every test also fails if the browser logs a console error, throws an uncaught exception,
or has a network request fail (unless the test deliberately simulates that failure).

## Run

```bash
npm install                       # at the repo root, installs client + server
cd e2e
npm install
npx playwright install chromium   # first time only
npm test
```

Playwright starts `server` (port 4000) and `client` (port 3000) with `npm run dev` automatically.
If both are already running, it reuses them. The server needs `DATABASE_URL` and Supabase settings
to start; when they are not set, the config passes placeholders, because these tests only use the
in-memory `/api/tasks` routes.

Other commands:

| Command | What it does |
| --- | --- |
| `npm run test:headed` | Run with a visible browser window |
| `npm run test:ui` | Interactive Playwright UI (step through tests, see each action) |
| `npm run report` | Open the HTML report from the last run |

### Real sign-in and database task suites

`tests/supabase-auth.spec.ts` and `tests/supabase-tasks.spec.ts` sign in with the seeded accounts against a
local Supabase and use the `/api/task-instances` endpoints. Tests that complete a task reopen it as the
location manager afterwards, so they can be re-run without resetting the database.
Set up local sign-in first ([supabase/README.md](../supabase/README.md#local-seed-data-and-sign-in)), then:

```bash
E2E_SUPABASE=1 npm test            # PowerShell: $env:E2E_SUPABASE=1; npm test
```

With `E2E_SUPABASE=1` only these suites run, using your `server/.env` and `client/.env.local`.
Without it, the demo suites run and Supabase sign-in is switched off for the client, even if
`client/.env.local` configures it. If you already have `npm run dev:client` running with Supabase
configured, stop it first so Playwright starts a client in the right mode.

## What is covered (27 demo tests + 14 real sign-in and database task tests)

**Sign-in and access** (`tests/auth-and-navigation.spec.ts`)
- Unauthenticated users are redirected to sign-in
- Each role (Corporate, Brand, Manager, Employee) can sign in and reach the dashboard
- Brand choice is kept in the session; the session survives a reload; sign out works
- Role rules: Employees and Managers cannot see or open Compliance; Corporate sees every screen
- Every screen renders without console errors
- MOV check: the daily checklist and the manager rollup are reachable within two actions after sign-in

**Tasks** (`tests/tasks.spec.ts`)
- Tasks load from the API, grouped into Opening / Midday / Closing, with progress and an Overdue list
- Complete / un-complete a task (including an overdue one); changes are verified through the API and after a reload
- Create a task (with section), edit its description, delete it; each change is verified through the API
- A task cannot be saved without a description; Cancel discards the form
- Employees can complete tasks but cannot add, edit or delete them
- API down: an error banner with Retry appears, and Retry recovers
- API rejects an update: the optimistic UI change is rolled back and the error is shown

**Real sign-in** (`tests/supabase-auth.spec.ts`, needs `E2E_SUPABASE=1`)
- Email and password replace the preview-role picker; a wrong password shows an error
- Employee, Brand Admin, Organization Admin and a Taco Verde manager each get their own name,
  role, brand and location count from `/api/me`; no demo role switcher; Compliance only for admins
- Only an Organization Admin can switch brands; a Taco Verde manager lands in Taco Verde
- The session survives a reload; sign out clears the Supabase session
- `/api/me` returns 401 without an access token

**Database tasks** (`tests/supabase-tasks.spec.ts`, needs `E2E_SUPABASE=1`)
- An employee sees today's tasks for their location by shift, including timed occurrences at local times
- An employee completes a task (saved, survives reload) but cannot reopen it; a location manager reopens it
- A reading outside the task's bounds is rejected; a valid reading and notes are saved and shown
- Past days can be browsed; a brand admin browses every brand location read-only with an All Locations rollup
- A Taco Verde manager sees only Taco Verde tasks

## Notes

- The API keeps tasks in memory, so each test calls `POST /api/tasks/reset` first and tests run one at a time.
- The demo suites use the demo role picker; the real sign-in suite covers Supabase Auth.
- Dashboard, Knowledge, Training, Compliance and the All Locations rollup use static mock data,
  so the tests check that they render and are access-controlled, not their numbers.
- Failed runs keep a screenshot, video and trace in `test-results/`
  (`npx playwright show-trace <path-to-trace.zip>` replays the run step by step).

The real sign-in suite also covers Harbor Kitchen, a synthetic brand in a separate
organization. The local onboarding seed assigns its manager two stores and gives
Harbor Central one task for the Los Angeles date when the seed runs. Harbor West
has an empty checklist. Run this scenario against a disposable local database
seeded on the day of the test. Use the existing local test password with
`onboarding.manager@opshub.test` to walk through it manually.
