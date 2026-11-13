import { type RequestHandler } from 'express';
import { withUserTransaction } from '../db/transaction.js';
import type { TaskInstanceStateRow } from '../types/task-instance.js';
import { Pool } from 'pg';

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const completeQuery = `
  SELECT id, completed_at, completed_by, recorded_value, notes
  FROM public.complete_task_instance($1, $2, $3)
`

const reopenQuery = `
  SELECT id, completed_at, completed_by, recorded_value, notes
  FROM public.reopen_task_instance($1)
`;

function toCompletionResponse(row: TaskInstanceStateRow) {
  return {
    id: row.id,
    completedAt: row.completed_at,
    completedBy: row.completed_by,
    // API readings use JS numbers; exact decimal precision is not preserved.
    recordedValue:
      row.recorded_value === null
        ? null
        : Number(row.recorded_value),
    notes: row.notes,
  };
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