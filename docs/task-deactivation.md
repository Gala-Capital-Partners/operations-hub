# Task-definition deactivation

## API

```http
POST /api/task-definitions/:id/deactivate
Authorization: Bearer <access token>
```

No body (or `{}`). Response `200`:

```json
{ "id": "…", "isActive": false, "deactivatedAt": "…", "cancelledInstanceCount": 4 }
```

| Status | Code | When |
|---|---|---|
| 200 | — | Deactivated, or already inactive (`cancelledInstanceCount: 0`, nothing changes) |
| 400 | `INVALID_DEFINITION_ID` / `INVALID_BODY` | Non-UUID id, or a non-empty body |
| 401 | — | Missing or invalid access token |
| 403 | `TASK_DEFINITION_FORBIDDEN` | Missing, other-organization or unauthorized definition (one response) |
| 415 | `UNSUPPORTED_MEDIA_TYPE` | A body that is not JSON |

The listing response (`GET /api/task-instances`) now includes each task's
`definitionId`, so a checklist item can offer "deactivate this task".

## Rules

- **Who:** the same rule as creation, `tasks.manage` for the definition's target.
  Location managers can deactivate their store's definitions; brand-wide
  definitions need a brand or organization admin. Employees cannot. The brand
  (and, for a store definition, the store) must still be active.
- **Stops generation:** `is_active = false`. Inactive definitions generate nothing
  on either path, and the nightly scheduler no longer lists them.
- **Cancels future, uncompleted occurrences:** rows with
  `scheduled_day > (now() AT TIME ZONE timezone_snapshot)::date`, no completion
  and no earlier cancellation get `cancelled_at` / `cancelled_by`. Each row is
  compared with its own store's local date, so a brand-wide definition keeps
  today's checklist in every store, whatever the timezone.
- **Preserves:** today's and past occurrences (open or completed), completed
  future occurrences, and every completion/reopening event. Nothing is deleted.
- A completed future occurrence of an inactive definition cannot be reopened while its scheduled day is still in the future at that store (HTTP 409). Today and past days follow the usual reopening rules.
- **Cancelled rows** are kept for audit, excluded from the checklist listing and
  the manager summary, and rejected by complete/reopen (`409`).
- **Audit:** `task_definitions.deactivated_at` / `deactivated_by` record who and
  when; a repeat call keeps the original values.
- Reactivation is not supported yet. Cancelled rows also block regeneration of
  the same occurrence (`ON CONFLICT DO NOTHING`), so reactivation will need its
  own rule.

## Database

Migration `20261125000000_add_task_definition_deactivation.sql`:

- Adds the audit/cancellation columns with pair CHECKs, and
  `cancelled_at IS NULL OR completed_at IS NULL`.
- `public.deactivate_task_definition(uuid)` (runtime only) is owned by the new
  NOLOGIN `operations_hub_deactivation_writer`, which can update only
  `is_active`, `deactivated_at`, `deactivated_by` and `cancelled_at`,
  `cancelled_by`.
- Lock order: organization advisory lock, then a per-definition advisory lock,
  then the definition row. `identity_access.insert_task_occurrences` now takes
  the same per-definition lock, so the scheduler (which has no organization
  lock) and deactivation serialize: either deactivation sees and cancels the
  scheduler's new rows, or the scheduler sees the definition is inactive.
- `identity_access.change_task_completion` rejects cancelled rows with `55000`.

Tests: `supabase/tests/task_definition_deactivation_verification.sql`
(authorization, per-store local dates, preservation, repeat calls, generation
stop, completion rejection) and `server/test/task-definition-deactivation.test.ts`
(HTTP mapping and transaction handling).
