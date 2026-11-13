# Controlled task completion and reopening

## API for the authenticated backend

Inside `withUserTransaction` (verified actor, runtime role, READ COMMITTED):

```sql
SELECT * FROM public.complete_task_instance($1, $2, $3);
-- $1 instance UUID, $2 optional numeric reading, $3 optional plain-text notes
SELECT * FROM public.reopen_task_instance($1);
```

Both return the updated task-instance row. Omitted completion inputs default to
NULL. The actor is derived from transaction-local `app.user_id`, never a function
argument. These are database entry points, not HTTP endpoints or public Supabase
RPC access: anon/authenticated cannot execute them.
The backend must verify the access token before setting `app.user_id`; the
transaction setting itself is not proof of authentication.

## Behavior

- Completion requires `task_instances.complete` for the instance's active location
  and brand. Reopening requires `task_instances.reopen`. The active-user and scoped
  permission helpers enforce organization isolation. Org/brand admin alone does
  not grant these actions; a separate applicable location role is required.
  This follows the [approved permission matrix](db-design.md#approved-initial-permission-matrix):
  employees can complete, and location managers can complete and reopen, within
  their assigned locations. These functions do not introduce new role grants.
- Inactive/missing actors and unauthorized/missing instances are denied. Hidden
  and nonexistent instance IDs use the same authorization error.
- Repeated completion or reopening in the requested state raises a conflict,
  without overwriting values or inserting an event. This is not request-ID-based
  idempotency; after a network timeout the caller should refetch state.
- Numeric readings and notes are independently optional. Supplied readings must
  be finite and within snapshotted inclusive bounds. Blank notes become NULL;
  meaningful notes retain formatting and must be at most 2000 characters.
- Completion writes the verified actor and one database timestamp, and copies the
  exact reading/notes to a completion event. Reopening clears current completion
  fields/value/notes and appends an empty reopening event, retaining prior history.
- Snapshots, schedule, definition references and other fields cannot be changed
  by these functions. The existing updated_at trigger still runs.
- No deadline, future-date or historical cutoff is enforced: those business rules
  remain unconfirmed. Deactivating a definition does not by itself disable its
  already-generated instances. Locations/brands and actors must remain active.

## Atomicity and concurrency

The functions take the same organization advisory lock as existing assignment
writers, then lock the permitted instance row. After any wait, they recheck active
identity and scoped permission using a fresh READ COMMITTED statement snapshot.
Two competing state changes serialize. Revocation committed while waiting is
observed before the operation proceeds. Other isolation levels are rejected.

The state update and audit insertion are in the same transaction. Any exception,
including audit insertion failure, rolls back the function's changes. The caller
must still commit the surrounding transaction; functions do not commit it.

This coarse lock serializes task writes within an organization, including writes
to different instances. It favors consistency with the existing identity-write
protocol for the MVP. Measure contention before replacing it with finer locks.
Future authorization-mutating writers must follow the same lock protocol;
arbitrary privileged SQL that ignores it is outside that serialization guarantee.

## Privileges and errors

A dedicated NOLOGIN, NOBYPASSRLS task-writer role owns SECURITY DEFINER entry
points with an empty search_path. Explicit writer-only RLS policies permit the
operations; table grants allow only SELECT, completion-column UPDATE and event
INSERT. Runtime cannot assume this role, invoke the internal mutation helper,
write tables directly, or alter/delete history. Privileged administrators still
can change data; this is not tamper-proof audit storage.

| SQLSTATE | Meaning | Suggested API handling |
|---|---|---|
| 42501 | Missing/unauthorized identity or target | 403 with generic message |
| 55000 | Already in requested state | 409; refetch current state |
| 22004 | Missing instance argument | 400 |
| 22023 | Invalid numeric reading or oversized notes | 400 |
| 25000 | Unsupported transaction isolation | Backend configuration error |

The shared `identity_access.lock_assignment_organization()` helper currently
reports `Assignment writes require READ COMMITTED isolation` for SQLSTATE `25000`.
Task writes reuse that helper, so this message also applies to completion and
reopening. Treat it as a backend transaction-configuration error, not a user
permission or input error; callers must use READ COMMITTED.

Map only recognized errors in the task operation context; do not expose arbitrary
raw database messages. These HTTP mappings are guidance, not implemented routes.

## Verification and remaining work

The SQL suite executes calls as operations_hub_runtime and covers scopes, denied
actors, inactive resources, invalid input, optional values/notes, state conflicts,
unchanged snapshots, audit consistency and rollback on injected event failure.
The disposable harness additionally tests concurrent complete/reopen, revoked
assignments and deactivated callers while waiting, and isolation-level rejection.

Definition/history read policies remain unchanged pending product clarification.
Definition editing, generation, HTTP integration and frontend work remain separate.
