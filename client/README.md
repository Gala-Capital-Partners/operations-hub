# GalaPartnerAtlas — Frontend (Next.js)

OpsHub web app: **Next.js 16 (App Router) + React 19 + TypeScript + Tailwind CSS v4**, originally converted from the Figma Make export.

## Run it

Requires **Node 22** (see the root `package.json` engines). From the repo root:

```bash
npm install
npm run dev:server          # http://localhost:4000 (see server/README.md for its setup)
npm run dev:client          # http://localhost:3000
```

Copy `.env.example` to `.env.local` and fill in:

| Variable | Purpose |
| --- | --- |
| `NEXT_PUBLIC_API_URL` | Backend API base URL. Defaults to `http://localhost:4000/api`. |
| `NEXT_PUBLIC_SUPABASE_URL` | Supabase API URL (`npx supabase status` → API URL). |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | Supabase publishable key (`npx supabase status`). Safe in the browser. |

Never put a Supabase secret/service-role key or a database URL in `NEXT_PUBLIC_*` variables: everything prefixed that way is shipped to the browser. Restart `npm run dev:client` after changing `.env.local`.

## Two sign-in modes

- **Real sign-in** (both Supabase variables set): email + password through Supabase Auth. After sign-in the app loads `GET /api/me`; the user's role, brands, stores and permissions come from the database, not from the login screen. Every API call sends the Supabase access token, and the backend enforces access again.
- **Demo mode** (Supabase variables empty): the original role/brand picker with no authentication. Its screens use the prototype `/api/tasks` and sample data.

Local test accounts (all with password `opshub-local-dev`) are created by `supabase/seed.sql` on `npx supabase db reset --local`; see [supabase/README.md](../supabase/README.md). They exist only in your local database.

Brands are data-driven in real sign-in: any brand returned by `/api/me` appears in the app. Brands without a theme in `src/lib/config.ts` get a default color and their initials.

## Routes

| URL | Real sign-in | Demo mode | Roles |
| --- | --- | --- | --- |
| `/` | Email + password | Role + brand picker | everyone |
| `/dashboard` | **My Tasks Today** for the user's first store (employees, managers) and **Task completion by location** (managers, admins) | Sample KPIs, sales chart, prototype tasks | all |
| `/tasks` | Store checklist for one store-local day: complete (with optional reading/notes), reopen, **+ New task** | Prototype task list (in-memory API) | all |
| `/knowledge` | Sample data | Sample data | all |
| `/training` | Sample data | Sample data | all |
| `/compliance` | Sample data | Sample data | Org Admin, Brand Admin |

Knowledge, Training and Compliance have no backend yet; they show the sample data in `src/lib/mock-data.ts`. The sales numbers and compliance alert on the dashboard are shown only in demo mode.

### Tasks page (real sign-in)

- Lists `GET /api/task-instances` for the selected store and that store's local date, grouped by Opening / Midday / Closing, plus yesterday's unfinished tasks.
- **Complete / reopen** use `POST /api/task-instances/:id/complete` and `/reopen`. Buttons follow the user's permissions (`task_instances.complete`, `task_instances.reopen`); admins without a store role see a view-only notice.
- **+ New task** (shown with `tasks.manage` at the store) creates a task definition through `POST /api/task-definitions`: one-time, daily or weekly on chosen days; all day (optional due time) or at specific times; optional numeric reading with unit and range. Brand and organization admins can target every store in the brand. The backend generates the coming week of tasks immediately, so new tasks appear on the checklist right away.

## Structure

```
src/
  app/
    layout.tsx                 root layout, fonts, SessionProvider
    page.tsx                   "/" sign-in
    (app)/layout.tsx           signed-in shell (sidebar / mobile tab bar) + route guard
    (app)/<screen>/page.tsx
  components/
    screens/                   one component per screen; tasks-db-screen.tsx is the real Tasks page
    dashboard/                 my-tasks-today.tsx, location-rollup.tsx (real sign-in)
    tasks/                     create-task-dialog.tsx, task-instance-dialog.tsx; task-modal.tsx (demo)
    training/                  training sub-components (sample data)
    session-provider.tsx       demo vs. real session, Supabase sign-in, /api/me
    shell.tsx, icons.tsx, charts.tsx, motion.tsx
  hooks/
    use-task-instances.ts      database tasks for one store/day, optimistic complete/reopen
    use-task-summary.ts        per-store completion for the dashboard rollup
    use-tasks.ts               prototype /api/tasks (demo mode)
  lib/
    supabase.ts                browser Supabase client (publishable key only)
    auth.ts                    role/brand/permission helpers for the UI
    api/me.ts                  GET /api/me
    api/task-instances.ts      task-instance list/summary/complete/reopen + shared authenticated request
    api/task-definitions.ts    POST /api/task-definitions
    api/tasks.ts               prototype /api/tasks client (demo mode)
    types.ts, config.ts        shared types, brand themes, roles, nav
    mock-data.ts               sample data for demo mode and the non-task screens
    format.ts                  small formatting helpers
```

Permission checks in the UI only decide which controls to show. The backend and database enforce access on every request.
