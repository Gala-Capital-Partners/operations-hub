# Task recurrence storage contract

Status: database schema foundation only. Recurrence validation, date expansion,
materialization, and scheduler integration are not implemented in this change.

## Ownership and scope

GCP's kickoff calls for RRULE recurrence through a library and an idempotent
`materialize_task_instances(run_date)` operation. Student A provides the schema,
constraints, permissions, and SQL verification. Student B owns the recurrence
implementation and materialization. This document describes their database
interface without prescribing a TypeScript module or library version.

## Database contract

- `recurrence_rule`: NULL for a one-off on `start_date`; otherwise an uppercase,
  single-line RRULE value without the `RRULE:` prefix. FREQ must come first.
- The structural check permits DAILY, WEEKLY, MONTHLY, or YEARLY frequencies and
  limits the value to 512 characters. It does not validate all keys, combinations,
  numeric ranges, or calendar semantics.
- Embedded DTSTART, TZID, UNTIL, time-of-day selectors, RDATE, EXDATE, EXRULE,
  and RRULE fields are rejected. Store the date boundaries in their own columns.
- `start_date` and optional inclusive `end_date` are local calendar dates between
  2000-01-01 and 2199-12-31. End cannot precede start. One-off tasks require a
  NULL end date.
- `due_time` is an optional local wall-clock time, separate from recurrence dates.
- Instances are unique by `(definition_id, location_id, scheduled_day)`, allowing
  one instance per definition/location/day.
- Instances snapshot name, description, category, due time, and location timezone.
  The timezone check rejects blank values; it does not validate IANA names.

Examples of storage values are `FREQ=DAILY` and `FREQ=WEEKLY;BYDAY=MO,WE,FR`.
Database acceptance alone does not establish that a schedule is supported by the
application. Agree on the supported RRULE subset with the team before enabling
schedule creation.

## Requirements for the future recurrence implementation

Use a recurrence library for semantic validation and calendar calculation.
Validate before persistence and again when processing stored schedules; reject
unsupported or invalid rules with a useful error instead of silently skipping
or changing occurrences. Normalize rules to match the database storage format.
Define how DTSTART matches the rule and preserve the original start/count across
separate generation runs. Bound evaluation and backfills, and test performance;
a bounded output window alone does not guarantee bounded computation.

Derive each location's calendar day using its validated IANA timezone. Keep
calendar dates distinct from due timestamps. Define DST behavior before adding
exact overdue/reminder timestamps. Copy the actual location timezone into each
instance, preserving historical snapshots when definitions or locations change.

Materialization must check active definitions, brands, and locations; enforce
location-specific targets; and use an authorized database write path. Repeated
and concurrent runs must avoid duplicate instances without overwriting existing
snapshots, completion state, or history. Define future-instance edits,
cancellation, timezone changes, retries, and missed-run recovery with the team.

## Verification and remaining work

`supabase/tests/task_schema_verification.sql` verifies schema constraints and
default-deny privileges. Run it through the disposable database harness:

```bash
python3 supabase/tests/location_assignment_concurrency.py
```

Task-specific RLS and controlled writes remain follow-up work. The SQL tests do
not prove recurrence evaluation, materialization idempotency, or scheduler
behavior. Those require tests alongside their future implementation.
