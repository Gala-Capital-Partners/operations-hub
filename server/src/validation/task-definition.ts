import { isCalendarDate } from '../scheduling/calendar-date.js';
import { validateRecurrenceRule } from '../scheduling/recurrence.js';
import type { TaskDefinitionInput } from "../types/task-definition.js";

const allowedFields = [
  'brandId',
  'locationId',
  'name',
  'description',
  'category',
  'recurrenceRule',
  'startDate',
  'endDate',
  'scheduleMode',
  'scheduledTimes',
  'dueTime',
  'numericUnit',
  'numericMin',
  'numericMax',
] as const;

type TaskDefinitionField = (typeof allowedFields)[number];

// Values remain unknown until field validation succeeds.
type NormalizedTaskDefinitionBody = Record<TaskDefinitionField, unknown>;

type NormalizeResult =
  | { ok: true; value: NormalizedTaskDefinitionBody }
  | { ok: false; message: string };

const allowedFieldSet = new Set<string>(allowedFields);

function trimIfString(value: unknown): unknown {
  return typeof value === 'string' ? value.trim() : value;
}

// Only an omitted field gets a default.
// Explicit null values remain available for validation.
function defaultIfUndefined(
  value: unknown,
  fallback: unknown,
): unknown {
  return value === undefined ? fallback : value;
}

export function normalizeTaskDefinitionBody(
  body: unknown,
): NormalizeResult {
  if (
    typeof body !== 'object' ||
    body === null ||
    Array.isArray(body)
  ) {
    return {
      ok: false,
      message: 'Request body must be a JSON object.',
    };
  }

  const input = body as Record<string, unknown>;

  if (Object.keys(input).some(key => !allowedFieldSet.has(key))) {
    return {
      ok: false,
      message: 'Request body contains unsupported fields.',
    };
  }

  return {
    ok: true,
    value: {
      brandId: trimIfString(input.brandId),
      locationId: trimIfString(
        defaultIfUndefined(input.locationId, null),
      ),
      name: trimIfString(input.name),
      description: trimIfString(input.description),
      category: trimIfString(input.category),
      recurrenceRule: trimIfString(
        defaultIfUndefined(input.recurrenceRule, null),
      ),
      startDate: trimIfString(input.startDate),
      endDate: trimIfString(
        defaultIfUndefined(input.endDate, null),
      ),
      scheduleMode: trimIfString(
        defaultIfUndefined(input.scheduleMode, 'all_day'),
      ),
      scheduledTimes: Array.isArray(input.scheduledTimes)
        ? input.scheduledTimes.map(trimIfString)
        : defaultIfUndefined(input.scheduledTimes, []),
      dueTime: trimIfString(
        defaultIfUndefined(input.dueTime, null),
      ),
      numericUnit: trimIfString(
        defaultIfUndefined(input.numericUnit, null),
      ),
      numericMin: defaultIfUndefined(input.numericMin, null),
      numericMax: defaultIfUndefined(input.numericMax, null),
    },
  };
}
type ValidationResult =
  | { ok: true; value: TaskDefinitionInput }
  | { ok: false; field: TaskDefinitionField; message: string };

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// The API accepts minute precision; the database also supports seconds.
const TIME_RE = /^(?:[01]\d|2[0-3]):[0-5]\d$/;

function isUuid(value: unknown): value is string {
  return typeof value === 'string' && UUID_RE.test(value);
}


function isTime(value: unknown): value is string {
  return typeof value === 'string' && TIME_RE.test(value);
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value);
}

/**
 * Validate normalized input without querying the database.
 * Authorization and brand/location existence must be checked by the writer.
 * Recurrence semantics are validated separately using the recurrence library.
 */
export function validateTaskDefinitionBody(
  body: NormalizedTaskDefinitionBody,
): ValidationResult {
  const invalid = (
    field: TaskDefinitionField,
    message: string,
  ): ValidationResult => ({ ok: false, field, message });

  const {
    brandId, locationId, name, description, category, recurrenceRule,
    startDate, endDate, scheduleMode, scheduledTimes, dueTime,
    numericUnit, numericMin, numericMax,
  } = body;

  if (!isUuid(brandId)) return invalid('brandId', 'brandId must be a UUID.');
  if (locationId !== null && !isUuid(locationId)) {
    return invalid('locationId', 'locationId must be a UUID or null.');
  }
  if (typeof name !== 'string' || !name.trim() || name.includes('\0')) {
    return invalid('name', 'name must be nonblank text without null characters.');
  }
  // Keep these code-point limits aligned with the SQL length CHECKs.
  if ([...name].length > 200) {
    return invalid('name', 'name must be at most 200 characters.');
  }
  // Empty descriptions are allowed by the schema, but a string is required.
  if (typeof description !== 'string' || description.includes('\0')) {
    return invalid('description', 'description must be text without null characters.');
  }
  if ([...description].length > 2000) {
    return invalid('description', 'description must be at most 2000 characters.');
  }
  if (category !== 'Opening' && category !== 'Midday' && category !== 'Closing') {
    return invalid('category', 'category must be Opening, Midday, or Closing.');
  }
  if (!isCalendarDate(startDate)) {
    return invalid('startDate', 'startDate must be a real YYYY-MM-DD date between 2000 and 2199.');
  }
  if (endDate !== null && !isCalendarDate(endDate)) {
    return invalid('endDate', 'endDate must be null or a real YYYY-MM-DD date between 2000 and 2199.');
  }
  if (endDate !== null && endDate < startDate) {
    return invalid('endDate', 'endDate cannot precede startDate.');
  }
  const recurrence = validateRecurrenceRule(recurrenceRule, startDate);
  if (!recurrence.ok) {
    return invalid('recurrenceRule', recurrence.message);
  }
  if (recurrence.value === null && endDate !== null) {
    return invalid('endDate', 'One-time tasks must have a null endDate.');
  }
  if (scheduleMode !== 'all_day' && scheduleMode !== 'timed') {
    return invalid('scheduleMode', 'scheduleMode must be all_day or timed.');
  }
  if (!Array.isArray(scheduledTimes) || !scheduledTimes.every(isTime)) {
    return invalid('scheduledTimes', 'scheduledTimes must be an array of HH:mm times from 00:00 through 23:59.');
  }
  if (new Set(scheduledTimes).size !== scheduledTimes.length) {
    return invalid('scheduledTimes', 'scheduledTimes must not contain duplicates.');
  }
  if (scheduleMode === 'all_day' && scheduledTimes.length !== 0) {
    return invalid('scheduledTimes', 'All-day tasks must have an empty scheduledTimes array.');
  }
  if (scheduleMode === 'timed' && scheduledTimes.length === 0) {
    return invalid('scheduledTimes', 'Timed tasks must have at least one scheduled time.');
  }
  if (dueTime !== null && !isTime(dueTime)) {
    return invalid('dueTime', 'dueTime must be null or a time in HH:mm format.');
  }
  if (scheduleMode === 'timed' && dueTime !== null) {
    return invalid('dueTime', 'Timed tasks must have a null dueTime.');
  }
  if (numericUnit !== null && (
    typeof numericUnit !== 'string' || !numericUnit.trim() || numericUnit.includes('\0')
  )) {
    return invalid('numericUnit', 'numericUnit must be null or nonblank text without null characters.');
  }
  if (numericUnit !== null && [...numericUnit].length > 32) {
    return invalid('numericUnit', 'numericUnit must be at most 32 characters.');
  }
  if (numericMin !== null && !isFiniteNumber(numericMin)) {
    return invalid('numericMin', 'numericMin must be a finite number or null.');
  }
  if (numericMax !== null && !isFiniteNumber(numericMax)) {
    return invalid('numericMax', 'numericMax must be a finite number or null.');
  }
  if (numericMin !== null && numericMax !== null && numericMin > numericMax) {
    return invalid('numericMin', 'numericMin cannot exceed numericMax.');
  }

  return {
    ok: true,
    value: {
      brandId, locationId, name, description, category,
      recurrenceRule: recurrence.value,
      startDate, endDate, scheduleMode,
      scheduledTimes: [...scheduledTimes].sort(),
      dueTime, numericUnit, numericMin, numericMax,
    },
  };
}
