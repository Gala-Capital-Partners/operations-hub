import rrule from 'rrule';
import type { PoolClient } from 'pg';
import { isCalendarDate } from './calendar-date.js';
import { validateRecurrenceRule } from './recurrence.js';
import type {
  DefinitionSchedule,
  GenerationWindow,
  GenerationDefinition,
} from '../types/task-generation.js';

const { RRule } = rrule;
const DAY_MS = 86_400_000;
export const MAX_GENERATION_DAYS = 62;

type GenerationDefinitionRow = {
  id: string;
  recurrence_rule: string | null;
  start_date: string;
  end_date: string | null;
  definition_version: string;
  target_timezones: string[];
};

function calendarDate(value: string): Date {
  // UTC is a neutral representation of a calendar day, not the store's instant.
  return new Date(`${value}T00:00:00.000Z`);
}

/** Inclusive local-calendar window; no dependency on the server's timezone. */
export function occurrenceDates(
  def: DefinitionSchedule,
  window: GenerationWindow,
): string[] {
  if (!isCalendarDate(window.from) || !isCalendarDate(window.to)) {
    throw new RangeError(
      'Generation dates must be real YYYY-MM-DD dates between 2000 and 2199.',
    );
  }
  const days =
    calendarDate(window.to).getTime() - calendarDate(window.from).getTime();
  const span = days / DAY_MS + 1;
  if (span < 1 || span > MAX_GENERATION_DAYS) {
    throw new RangeError(
      `Generation windows must contain 1-${MAX_GENERATION_DAYS} calendar days.`,
    );
  }
  if (
    !isCalendarDate(def.startDate) ||
    (def.endDate !== null &&
      (!isCalendarDate(def.endDate) || def.endDate < def.startDate))
  ) {
    throw new RangeError('The definition has invalid date boundaries.');
  }
  const recurrence = validateRecurrenceRule(def.recurrenceRule, def.startDate);
  if (!recurrence.ok) throw new RangeError(recurrence.message);
  if (recurrence.value === null) {
    if (def.endDate !== null) {
      throw new RangeError('One-time definitions cannot have an endDate.');
    }
    if (window.from <= def.startDate && def.startDate <= window.to) {
      return [def.startDate];
    } else {
      return [];
    }
  }

  const from = window.from > def.startDate ? window.from : def.startDate;
  const to =
    def.endDate !== null && def.endDate < window.to ? def.endDate : window.to;
  if (from > to) return [];

  // Always retain the original DTSTART. Moving it to window.from would restart
  // COUNT and INTERVAL on every run. The supported year range and date-only
  // frequencies bound traversal to at most 200 years, with <=62 returned dates.
  const rule = new RRule(
    {
      ...RRule.parseString(recurrence.value),
      dtstart: calendarDate(def.startDate),
    },
    true,
  );
  return rule
    .between(calendarDate(from), calendarDate(to), true)
    .map((date) => date.toISOString().slice(0, 10));
}

function toDefinition(row: GenerationDefinitionRow): GenerationDefinition {
  return {
    id: row.id,
    recurrenceRule: row.recurrence_rule,
    startDate: row.start_date,
    endDate: row.end_date,
    version: row.definition_version,
    targetTimezones: row.target_timezones,
  };
}

/** Call inside withUserTransaction; SQL checks tasks.manage for this definition. */
export async function loadManagerGenerationDefinition(
  db: PoolClient,
  definitionId: string,
): Promise<GenerationDefinition> {
  const result = await db.query<GenerationDefinitionRow>(
    `
    SELECT id, recurrence_rule, to_char(start_date, 'YYYY-MM-DD') AS start_date,
          to_char(end_date, 'YYYY-MM-DD') AS end_date, definition_version, target_timezones
    FROM public.task_definition_generation_input($1::uuid)
    `,
    [definitionId],
  );
  if (result.rows.length !== 1) {
    throw new Error('Generation input did not return one definition.');
  }
  return toDefinition(result.rows[0]);
}

/** Call inside a transaction that has SET LOCAL ROLE operations_hub_scheduler. */
export async function loadSchedulerGenerationDefinitions(
  db: PoolClient,
): Promise<GenerationDefinition[]> {
  const result = await db.query<GenerationDefinitionRow>(`
    SELECT id, recurrence_rule, to_char(start_date, 'YYYY-MM-DD') AS start_date,
           to_char(end_date, 'YYYY-MM-DD') AS end_date, definition_version, target_timezones
    FROM public.scheduler_active_task_definitions()
  `);
  return result.rows.map(toDefinition);
}

/**
 * Shared generation operation. The caller owns the transaction and identity.
 * SQL expands dates into active stores/time slots and copies authoritative
 * snapshots. A stale version raises SQLSTATE 40001: roll back, reload, and retry
 * the entire operation; never retry the old date list or reset completion state.
 */
export async function generateTaskInstances(
  db: PoolClient,
  definition: GenerationDefinition,
  window: GenerationWindow,
  mode: 'manager' | 'scheduler' = 'manager',
  timezone: string | null = null,
): Promise<{ matchingDates: string[]; inserted: number }> {
  const days = occurrenceDates(definition, window);
  const queries = {
    manager: `SELECT public.generate_task_instances($1::uuid, $2::date[], $3::text, $4::text) AS inserted`,
    scheduler: `SELECT public.scheduler_generate_task_instances($1::uuid, $2::date[], $3::text, $4::text) AS inserted`,
  };
  if (mode !== 'manager' && mode !== 'scheduler') {
    throw new Error('Unsupported generation mode.');
  }
  // Each SQL call checks authorization/version even when its date list is empty.
  // With no target timezones the rolling helper makes no insert calls; the
  // manager input reader has already checked authorization.
  const result = await db.query<{ inserted: number }>(queries[mode], [
    definition.id,
    days,
    definition.version,
    timezone,
  ]);
  if (result.rows.length !== 1) {
    throw new Error('Generation did not return an insertion count.');
  }
  return { matchingDates: days, inserted: result.rows[0].inserted };
}

/** UTC is only a calendar-date container; this avoids DST changing the day count. */
function shiftDay(day: string, offset: number): string {
  return new Date(calendarDate(day).getTime() + offset * DAY_MS)
    .toISOString()
    .slice(0, 10);
}

/** Seven local dates including today. Nonzero catch-up is an explicit backfill override. */
export function generationWindow(
  now: Date,
  timezone: string,
  catchUpDays = 0,
): GenerationWindow {
  if (
    !Number.isFinite(now.getTime()) ||
    !Number.isInteger(catchUpDays) ||
    catchUpDays < 0 ||
    catchUpDays > 7
  ) {
    throw new RangeError('A valid instant and 0-7 catch-up days are required.');
  }
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: timezone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(now);
  const part = (name: string) =>
    parts.find((value) => value.type === name)!.value;
  const today = `${part('year')}-${part('month')}-${part('day')}`;
  const window = {
    from: shiftDay(today, -catchUpDays),
    to: shiftDay(today, 6),
  };
  if (!isCalendarDate(window.from) || !isCalendarDate(window.to)) {
    throw new RangeError('Generation window is outside supported years.');
  }
  return window;
}

/**
 * The caller owns the transaction. Each timezone receives only its local window.
 * Both paths default to today forward. Historical backfills require a deliberate
 * override and eligibility review; do not use them for routine scheduling.
 */
export async function generateRollingTaskInstances(
  db: PoolClient,
  definition: GenerationDefinition,
  now: Date,
  mode: 'manager' | 'scheduler' = 'manager',
  catchUpDays = 0,
): Promise<number> {
  let inserted = 0;
  for (const timezone of new Set(definition.targetTimezones)) {
    const window = generationWindow(now, timezone, catchUpDays);
    const result = await generateTaskInstances(
      db,
      definition,
      window,
      mode,
      timezone,
    );
    inserted += result.inserted;
  }
  return inserted;
}
