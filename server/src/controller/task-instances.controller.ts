import { type RequestHandler } from 'express';
import { withUserTransaction } from '../db/transaction.js';
import type { TaskInstanceStateRow, TaskInstanceListRow } from '../types/task-instance.js';
import { Pool } from 'pg';

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const completeQuery = `
  SELECT id, completed_at, completed_by, recorded_value, notes
  FROM public.complete_task_instance($1, $2, $3)
`;

const reopenQuery = `
  SELECT id, completed_at, completed_by, recorded_value, notes
  FROM public.reopen_task_instance($1)
`;

const readQuery = `
  SELECT
    t.id,
    t.name_snapshot,
    t.description_snapshot,
    t.category_snapshot,
    t.scheduled_at,
    to_char(t.scheduled_day, 'YYYY-MM-DD') AS scheduled_day,
    t.is_all_day_snapshot,
    t.timezone_snapshot,
    t.due_time_snapshot,
    t.completed_at,
    t.completed_by,
    t.recorded_value,
    t.notes,
    t.numeric_unit_snapshot,
    t.numeric_min_snapshot,
    t.numeric_max_snapshot
  FROM public.task_instances AS t
  WHERE t.location_id = $1
    AND t.scheduled_day = $2
  ORDER BY t.scheduled_at, t.id
`;

const locationAccessQuery = `
  SELECT EXISTS (
    SELECT 1
    FROM identity_access.current_location_ids_with(
      'task_instances.read'
    ) AS permitted(location_id)
    WHERE permitted.location_id = $1
  ) AS allowed
`;

// API readings use JS numbers; exact decimal precision is not preserved.
function toOptionalNumber(value: string | null): number | null {
  return value === null ? null : Number(value);
}

function toCompletionResponse(row: TaskInstanceStateRow) {
  return {
    id: row.id,
    completedAt: row.completed_at,
    completedBy: row.completed_by,
    recordedValue: toOptionalNumber(row.recorded_value),
    notes: row.notes,
  };
}

function toTaskListResponse(rows: TaskInstanceListRow[]) {
  return rows.map((row) => ({
    id: row.id,
    name: row.name_snapshot,
    description: row.description_snapshot,
    category: row.category_snapshot,
    scheduledAt: row.scheduled_at,
    scheduledDay: row.scheduled_day,
    isAllDay: row.is_all_day_snapshot,
    timezone: row.timezone_snapshot,
    dueTime: row.due_time_snapshot,
    completedAt: row.completed_at,
    completedBy: row.completed_by,
    recordedValue: toOptionalNumber(row.recorded_value),
    notes: row.notes,
    numericUnit: row.numeric_unit_snapshot,
    numericMin: toOptionalNumber(row.numeric_min_snapshot),
    numericMax: toOptionalNumber(row.numeric_max_snapshot),
  }));
}

function mapTaskWriteError(err: unknown) {
  const code =
    err instanceof Error && 'code' in err
      ? err.code
      : undefined;

  switch (code) {
    case '22004':
    case '22023':
      return {
        status: 400,
        code: 'INVALID_TASK_INPUT',
        message: 'The supplied values do not meet the task requirements.',
      };

    case '42501':
      return {
        status: 403,
        code: 'TASK_OPERATION_FORBIDDEN',
        message: 'You are not authorized to perform this task operation.',
      };

    case '55000':
      return {
        status: 409,
        code: 'TASK_STATE_CONFLICT',
        message: 'Task is already in the requested state.',
      };

    default:
      return null;
  }
}

function isCalendarDate(value: unknown): value is string {
  if (typeof value !== 'string') return false;

  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!match) return false;

  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);

  // Match the supported task-definition date range.
  if (year < 2000 || year > 2199) return false;
  if (month < 1 || month > 12) return false;

  const leapYear =
    year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);

  const daysInMonth = [
    31, leapYear ? 29 : 28, 31, 30, 31, 30,
    31, 31, 30, 31, 30, 31,
  ];

  return day >= 1 && day <= daysInMonth[month - 1];
}

export function createTaskCompleteController(pool: Pool): RequestHandler {
  return async (req, res) => {
    const taskInstanceId = req.params.id;
    const body: unknown = req.body === undefined ? {} : req.body;

    if (
      typeof taskInstanceId !== 'string' ||
      !UUID_PATTERN.test(taskInstanceId)
    ) {
      return res.status(400).json({
        error: {
          code: 'INVALID_INSTANCE_ID',
          message: 'Task instance ID must be a UUID.',
        },
      });
    }

    if (typeof body !== 'object' || body === null || Array.isArray(body)) {
      return res.status(400).json({
        error: {
          code: 'INVALID_BODY',
          message: 'Request body must be a JSON object.',
        },
      });
    }

    const input = body as Record<string, unknown>;
    const allowedFields = new Set(['recordedValue', 'notes']);

    if (Object.keys(input).some(key => !allowedFields.has(key))) {
      return res.status(400).json({
        error: {
          code: 'INVALID_BODY',
          message: 'Only recordedValue and notes are accepted.',
        },
      });
    }
    const recordedValue = input.recordedValue ?? null;
    const notes = input.notes ?? null;

    if (
      recordedValue !== null &&
      (typeof recordedValue !== 'number' || !Number.isFinite(recordedValue))
    ) {
      return res.status(400).json({
        error: {
          code: 'INVALID_RECORDED_VALUE',
          message: 'Recorded value must be a finite number or null.',
        },
      });
    }

    if (
      notes !== null &&
      (typeof notes !== 'string' || [...notes].length > 2000)
    ) {
      return res.status(400).json({
        error: {
          code: 'INVALID_NOTES',
          message: 'Notes must be a string of at most 2000 characters or null.',
        },
      });
    }

    try {
      const result = await withUserTransaction(
        pool,
        res.locals.actorId,
        async (db) => {
          const data = await db.query<TaskInstanceStateRow>(completeQuery, [taskInstanceId, recordedValue, notes]);
          return toCompletionResponse(data.rows[0]);
        }
      )
      return res.status(200).json(result);
    } catch (err) {
      const mapped = mapTaskWriteError(err);

      if (!mapped) {
        throw err;
      }

      return res.status(mapped.status).json({
        error: {
          code: mapped.code,
          message: mapped.message,
        },
      });
    }
  }
}

export function createTaskReopenController(pool: Pool): RequestHandler {
  return async (req, res) => {
    const taskInstanceId = req.params.id;

    if (
      typeof taskInstanceId !== 'string' ||
      !UUID_PATTERN.test(taskInstanceId)
    ) {
      return res.status(400).json({
        error: {
          code: 'INVALID_INSTANCE_ID',
          message: 'Task instance ID must be a UUID.',
        },
      });
    }

    const body: unknown = req.body;

    if (
      body !== undefined &&
      (
        typeof body !== 'object' ||
        body === null ||
        Array.isArray(body) ||
        Object.keys(body).length > 0
      )
    ) {
      return res.status(400).json({
        error: {
          code: 'INVALID_BODY',
          message: 'Reopening accepts no body or an empty JSON object.',
        },
      });
    }

    try {
      const result = await withUserTransaction(
        pool,
        res.locals.actorId,
        async (db) => {
          const data = await db.query<TaskInstanceStateRow>(reopenQuery, [taskInstanceId]);
          return toCompletionResponse(data.rows[0]);
        }
      )
      return res.status(200).json(result);
    } catch (err) {
      const mapped = mapTaskWriteError(err);

      if (!mapped) {
        throw err;
      }

      return res.status(mapped.status).json({
        error: {
          code: mapped.code,
          message: mapped.message,
        },
      });
    }
  }
}

export function createTaskReadController(pool: Pool): RequestHandler {
  return async (req, res) => {
    const locationId = req.query.locationId;
    if (
      typeof locationId !== 'string' ||
      !UUID_PATTERN.test(locationId)
    ) {
      return res.status(400).json({
        error: {
          code: 'INVALID_LOCATION_ID',
          message: 'Location ID must be a UUID.',
        },
      });
    }

    const date = req.query.date;

    if (!isCalendarDate(date)) {
      return res.status(400).json({
        error: {
          code: 'INVALID_DATE',
          message:
            'Date must be a valid YYYY-MM-DD calendar date between 2000 and 2199.',
        },
      });
    }

    const result = await withUserTransaction(
      pool,
      res.locals.actorId,
      async (db) => {
        const access = await db.query<{ allowed: boolean }>(
          locationAccessQuery,
          [locationId],
        );

        if (!access.rows[0].allowed) {
          return null;
        }

        const data = await db.query<TaskInstanceListRow>(
          readQuery,
          [locationId, date],
        );
        return toTaskListResponse(data.rows);
      },
    );

    if (result === null) {
      return res.status(403).json({
        error: {
          code: 'TASK_OPERATION_FORBIDDEN',
          message: 'You are not authorized to read tasks at this location.',
        },
      });
    }

    return res.status(200).json({ tasks: result });
  };
}
