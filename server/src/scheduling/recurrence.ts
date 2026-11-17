import rrule from 'rrule';
import { isCalendarDate } from './calendar-date.js';

// Default import also works in the compiled Node ESM server with rrule's CJS build.
const { RRule } = rrule;

type RecurrenceResult =
  | { ok: true; value: string | null }
  | { ok: false; message: string };

const KEY_ORDER = ['FREQ', 'INTERVAL', 'COUNT', 'BYMONTH', 'BYMONTHDAY', 'BYDAY', 'WKST'];
const WEEKDAYS = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

/**
 * API subset of the storage contract in docs/task-recurrence.md.
 * SQL's recurrence_rule CHECK is only a structural backstop, not a parser.
 * Calendar dates use UTC midnight as a neutral representation, not a store's
 * actual scheduled instant. The materializer must later apply location timezone.
 */
export function validateRecurrenceRule(
  value: unknown,
  startDate: string,
): RecurrenceResult {
  const invalid = (message: string): RecurrenceResult => ({ ok: false, message });
  if (!isCalendarDate(startDate)) return invalid('A valid startDate is required.');
  if (value === null) return { ok: true, value: null };
  if (typeof value !== 'string' || value.length < 10 || value.length > 512) {
    return invalid('recurrenceRule must be null or an RRULE value of 10–512 characters.');
  }
  // Do not silently accept prefixes, multiline input, lowercase or embedded dates.
  if (!/^[A-Z]+=[A-Z0-9,+-]+(?:;[A-Z]+=[A-Z0-9,+-]+)*$/.test(value)) {
    return invalid('Use an uppercase RRULE value without the RRULE: prefix or whitespace.');
  }
  const fields = new Map<string, string>();
  for (const part of value.split(';')) {
    const [key, entry] = part.split('=') as [string, string];
    if (!KEY_ORDER.includes(key)) return invalid(`Unsupported recurrence field: ${key}.`);
    if (fields.has(key)) return invalid(`Duplicate recurrence field: ${key}.`);
    fields.set(key, entry);
  }
  const frequency = fields.get('FREQ');
  if (!frequency || !['DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY'].includes(frequency)) {
    return invalid('FREQ must be DAILY, WEEKLY, MONTHLY, or YEARLY.');
  }
  for (const [key, max] of [['INTERVAL', 366], ['COUNT', 73049]] as const) {
    const entry = fields.get(key);
    if (entry !== undefined) {
      const number = Number(entry);
      if (!/^\d+$/.test(entry) || !Number.isSafeInteger(number) || number < 1 || number > max) {
        return invalid(`${key} must be an integer between 1 and ${max}.`);
      }
      fields.set(key, String(number));
    }
  }
  for (const [key, min, max] of [['BYMONTH', 1, 12], ['BYMONTHDAY', -31, 31]] as const) {
    const entry = fields.get(key);
    if (entry === undefined) continue;
    if (key === 'BYMONTH' && frequency !== 'YEARLY') {
      return invalid('BYMONTH is supported only with YEARLY.');
    }
    if (key === 'BYMONTHDAY' && frequency !== 'MONTHLY' && frequency !== 'YEARLY') {
      return invalid('BYMONTHDAY is supported only with MONTHLY or YEARLY.');
    }
    const tokens = entry.split(',');
    const numbers = tokens.map(Number);
    if (tokens.some(token => !/^-?\d+$/.test(token)) ||
        numbers.some(number => !Number.isInteger(number) || number === 0 || number < min || number > max) ||
        new Set(numbers).size !== numbers.length) {
      return invalid(`${key} must contain unique nonzero integers between ${min} and ${max}.`);
    }
    fields.set(key, numbers.sort((a, b) => a - b).join(','));
  }
  const byDay = fields.get('BYDAY');
  if (byDay !== undefined) {
    if (frequency !== 'WEEKLY') return invalid('BYDAY is currently supported only with WEEKLY.');
    const days = byDay.split(',');
    if (days.some(day => !WEEKDAYS.includes(day)) || new Set(days).size !== days.length) {
      return invalid('BYDAY must contain unique weekdays such as MO,WE,FR.');
    }
    fields.set('BYDAY', WEEKDAYS.filter(day => days.includes(day)).join(','));
  }
  const weekStart = fields.get('WKST');
  if (weekStart !== undefined && (frequency !== 'WEEKLY' || !WEEKDAYS.includes(weekStart))) {
    return invalid('WKST must be a weekday and is supported only with WEEKLY.');
  }
  // FREQ first matches the existing SQL check; stable ordering aids comparisons.
  const canonical = KEY_ORDER.filter(key => fields.has(key))
    .map(key => `${key}=${fields.get(key)}`).join(';');
  const start = new Date(`${startDate}T00:00:00.000Z`);
  try {
    const rule = new RRule({ ...RRule.parseString(canonical), dtstart: start }, true);
    // Require DTSTART to be an occurrence. Only evaluate this one calendar day,
    // never enumerate an unbounded rule with all().
    if (rule.between(start, start, true).length !== 1) {
      return invalid('startDate must match the recurrence rule and be its first occurrence.');
    }
  } catch {
    return invalid('recurrenceRule could not be parsed by the recurrence library.');
  }
  return { ok: true, value: canonical };
}
