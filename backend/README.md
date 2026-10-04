# GalaPartnerAtlas — Backend (Tasks API)

Minimal **Express 5 + TypeScript** API. No database yet: tasks are kept **in memory**, seeded with the mock data from the Figma design. Restarting the server resets the data.

## Run it

```bash
npm install
npm run dev        # http://localhost:4000  (auto-reloads on change)
```

Optional: copy `.env.example` to `.env` to change `PORT` or `CORS_ORIGIN` (default allows `http://localhost:3000`).

Production build: `npm run build && npm start`.

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

## Endpoints

| Method | Path                | Description                                                   |
| ------ | ------------------- | ------------------------------------------------------------- |
| GET    | `/api/health`       | Health check                                                  |
| GET    | `/api/tasks`        | List tasks. Query filters: `date`, `from`, `to`, `cat`, `done` |
| GET    | `/api/tasks/:id`    | Get one task                                                  |
| POST   | `/api/tasks`        | Create. Required: `label`, `cat`, `date`                       |
| PATCH  | `/api/tasks/:id`    | Partial update, e.g. `{ "done": true }`                        |
| DELETE | `/api/tasks/:id`    | Delete (204)                                                  |
| POST   | `/api/tasks/reset`  | Restore the seed data (demo helper)                           |

Errors look like `{ "error": { "message": "...", "details": ["..."] } }` with status 400 / 404.

Examples:

```bash
curl http://localhost:4000/api/tasks?done=false
curl -X POST http://localhost:4000/api/tasks -H "Content-Type: application/json" \
  -d '{"label":"Restock napkins","cat":"Closing","date":"2026-08-19"}'
curl -X PATCH http://localhost:4000/api/tasks/3 -H "Content-Type: application/json" -d '{"done":true}'
curl -X DELETE http://localhost:4000/api/tasks/3
```

## Adding a database later

All data access goes through `src/store/task.store.ts`. Replace that file with a DB-backed version exposing the same functions (`listTasks`, `getTask`, `createTask`, `updateTask`, `deleteTask`) — routes and validation stay the same.

```
src/
  index.ts                  starts the server
  app.ts                    express app, CORS, JSON, error handling
  routes/tasks.routes.ts    /api/tasks endpoints
  validation/task.ts        request body validation
  store/task.store.ts       in-memory repository
  data/tasks.seed.ts        mock tasks from the design
  types/task.ts             Task types
```
