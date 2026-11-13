# Task recurrence storage contract

Status: database schema foundation only. Recurrence validation, date expansion,
materialization, and scheduler integration are not implemented in this change.

## Generator quick reference

- Use RRULE for dates and `task_definitions.scheduled_times` for timed slots.
- All-day mode emits one local-midnight anchor per matching date; timed mode
  emits one occurrence per configured time, subject to the agreed DST policy.
- Copy mode, timezone, instructions and numeric units/bounds into each instance.
- Reuse the same scheduled instant on retries; never overwrite historical rows.
- Do not use `scheduled_at` as an automatic visibility cutoff or deadline.
- Generation and definition writers remain unimplemented; direct runtime table
  writes are denied. Controlled completion/reopening now exist; see
  [task completion](task-completion.md).

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
- `schedule_mode` is `all_day` (the legacy/default mode) or `timed`.
- `scheduled_times` is a non-null `time[]`, defaulting to an empty array.
  Timed definitions need at least one local time; all-day definitions need none.
  A pure immutable helper checks one dimension, conventional 1-based indexing,
  no NULL elements, no duplicate times, and no 24:00. Midnight is allowed.
  Array order has no meaning; sort times when displaying or expanding them.
- Mode, times and due time must be changed in ONE statement. Immediate CHECKs
  enforce a valid final row. There are no child-table or schedule triggers.
- `due_time` is permitted only for all-day definitions; timed definitions require
  NULL. This avoids assigning one daily deadline to several timed occurrences.
  Exact all-day overdue/DST behavior and timed deadlines remain future decisions.
- Instances are unique by `(definition_id, location_id, scheduled_at)`. Multiple
  timed occurrences on the same local date are allowed; equivalent instants with
  different UTC-offset notation still collide.
- `scheduled_at` is a required finite instant identifying the occurrence, not a
  generation/completion timestamp or a deadline. `scheduled_day` must equal its
  local date in `timezone_snapshot`.
- `is_all_day_snapshot` is required. All-day instances use PostgreSQL's local
  midnight conversion as a deterministic anchor, not a midnight deadline. A
  partial unique index also limits all-day instances to one per definition,
  location, and local date. Existing date-only instances are upgraded as all-day;
  their due times are preserved. Neither new column has a default.
- For unusual midnight timezone transitions, the all-day anchor follows
  PostgreSQL's conversion. A wholly skipped local date is rejected by the date
  consistency constraint. Generators must match this convention; they must not
  silently move an occurrence to a different local date.
- Instances snapshot name, description, category, due time, and location timezone.
  Conversion checks reject timezone names PostgreSQL cannot resolve, but do not
  restrict its accepted names to IANA names; controlled writers must validate IANA
  zones and copy the location timezone rather than trusting client input.

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

Task-instance read RLS and controlled completion/reopening exist;
definition/history policies and definition writers remain follow-up work. The SQL tests do
not prove recurrence evaluation, materialization idempotency, or scheduler
behavior. Those require tests alongside their future implementation.

## Scheduling integration still required

Definition storage uses date-only RRULE plus an explicit local-time array. For example,
`FREQ=DAILY`, mode `timed`, and `scheduled_times = ARRAY[TIME '10:00', TIME '14:00', TIME '18:00']` represent three
occurrences per matching date at each eligible location. The generator converts
those local date/time pairs in the location timezone into scheduled instants.
Hourly RRULEs remain unsupported; fixed times implement the multiple-daily MVP.
RRULE COUNT counts matching dates in this split model, not the expanded time slots.
Confirm the UI wording and test that distinction in Student B's generator.

Student B and the database owner must agree on DST gap/fold handling before
enabling timed generation. Do not silently let a library normalize missing times.
For a repeated fall-back wall time, storage can distinguish both instants; this
is not a decision that the generator should produce both. Do not normalize away
UTC offsets when constructing occurrence identity.

On retries, calculate the same scheduled instant and preserve existing rows and
snapshots. A schedule or timezone edit that changes instants may create different
keys; uniqueness alone cannot reconcile already-generated future tasks. Define
that edit/cancellation behavior before enabling writers. Controlled writes must
also prevent unintended mixtures of all-day and timed occurrences for one schedule.

`task_occurrence_verification.sql` covers multiple daily occurrences, duplicate
instants, all-day uniqueness, local-date consistency, session-timezone independence,
and fall-back representation. These tests do not prove recurrence generation or
end-to-end scheduler idempotency.

## Definition storage verification and access

`task_definition_times_verification.sql` checks mode/array consistency, atomic
row updates, invalid/duplicate/NULL/multidimensional times, deadline restrictions,
and denied runtime access. Existing definition RLS and write restrictions apply
to the new columns. No separate table, cross-row validator, or deferred schedule
trigger is used. Future controlled APIs must address stale edits (for example,
optimistic version checks): row constraints prevent invalid schedules, not lost
updates. The array has no per-slot IDs or metadata; those would warrant revisiting
a child-table model.

The materializer maps `schedule_mode = 'all_day'` to `is_all_day_snapshot = true`,
and copies NULL due time for timed occurrences. Existing instance snapshots are
not rewritten when a definition changes.

This migration replaces an unreleased draft under the same filename. If that
older child-table draft was applied in a retained database, do not assume migration
replay upgrades it: rebuild only a disposable database or prepare an explicit
forward migration preserving its time rows.

Timezone conversions use PostgreSQL's installed timezone rules. A tzdata update
may change historical conversions and affect CHECK validation during updates or
restore; verify affected data during timezone-rule upgrades. Stored instants are
not automatically recalculated.

## Completion data

Numeric readings and plain-text notes are independently optional. There is no
required-reading flag to copy. Continue snapshotting numeric units and bounds;
validate supplied readings against the snapshots. Notes have a 2000-character
limit on instances and completion events. Absent notes use NULL; non-NULL notes
must contain a non-whitespace character. APIs should normalize blank input to
NULL before persistence. Clearing completion on reopening must
clear current value and notes without changing earlier events. These fields do
not affect date/time generation or occurrence identity.
