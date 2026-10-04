# GalaPartnerAtlas — Frontend (Next.js)

OpsHub web app, converted from the Figma Make export (`../Frontend`) to **Next.js 16 (App Router) + React 19 + TypeScript + Tailwind CSS v4**.

## Run it

```bash
npm install
npm run dev          # http://localhost:3000
```

The Tasks screens talk to the backend, so start it too (see `../backend`):

```bash
cd ../backend && npm install && npm run dev   # http://localhost:4000
```

API URL defaults to `http://localhost:4000/api`. To change it, copy `.env.example` to `.env.local` and edit `NEXT_PUBLIC_API_URL`.

## Routes

| URL           | Screen                              | Roles                          |
| ------------- | ----------------------------------- | ------------------------------ |
| `/`           | Sign in (pick role + brand)         | everyone                       |
| `/dashboard`  | KPIs, sales chart, today's tasks    | all                            |
| `/knowledge`  | Knowledge base                      | all                            |
| `/tasks`      | Task list + add / edit / delete     | all (managers+ can edit)       |
| `/training`   | Courses, quiz, rewards, leaderboard | all                            |
| `/compliance` | Document expiry tracking            | Corporate Admin, Brand Admin   |

Sign-in is still the demo flow from the design (no real auth). The chosen role/brand is kept in `localStorage`.

## Structure

```
src/
  app/
    layout.tsx            root layout, fonts, SessionProvider
    page.tsx              "/" sign-in
    (app)/layout.tsx      signed-in shell (sidebar / mobile tab bar) + route guard
    (app)/<screen>/page.tsx
  components/
    screens/              one component per screen (from the Figma export)
    tasks/task-modal.tsx  add / edit task modal
    training/             training sub-components
    shell.tsx, icons.tsx, charts.tsx, motion.tsx, session-provider.tsx
  hooks/use-tasks.ts      loads tasks from the API, optimistic create/update/delete
  lib/
    api/tasks.ts          typed fetch client for /api/tasks
    types.ts, config.ts   shared types, brands/roles/nav
    mock-data.ts          static demo data for the non-task screens
    format.ts             small formatting helpers
```

Only **tasks** are backed by the API. The other screens (sales, knowledge base, training, compliance) still use the mock data in `src/lib/mock-data.ts`.
