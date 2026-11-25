import type { Pool } from 'pg';
import type { RequestHandler } from 'express';
import {
  loadManagerGenerationDefinition,
  generateRollingTaskInstances,
} from '../scheduling/generator.js';
import { withUserTransaction } from '../db/transaction.js';
import {
  normalizeTaskDefinitionBody,
  validateTaskDefinitionBody,
} from '../validation/task-definition.js';
import type {
  TaskDefinitionDeactivationRow,
  TaskDefinitionRow,
} from '../types/task-definition.js';

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const createDefinitionQuery = `
  SELECT d.id, d.brand_id, d.location_id, d.created_by,
         d.name, d.description, d.category, d.recurrence_rule,
         to_char(d.start_date, 'YYYY-MM-DD') AS start_date,
         to_char(d.end_date, 'YYYY-MM-DD') AS end_date,
         d.schedule_mode, d.scheduled_times, d.due_time,
         d.numeric_unit, d.numeric_min, d.numeric_max,
         d.is_active, d.created_at, d.updated_at
  FROM public.create_task_definition(
    $1::uuid, $2::uuid, $3::text, $4::text, $5::text, $6::text,
    $7::date, $8::date, $9::text, $10::time[], $11::time,
    $12::text, $13::numeric, $14::numeric
  ) AS d
`;

// Stops future generation, cancels uncompleted occurrences after each store's
// local today, and keeps today, the past and completed history. Repeat calls
// return the current state with a zero count.
const deactivateDefinitionQuery = `
  SELECT id, is_active, deactivated_at, cancelled_instance_count
  FROM public.deactivate_task_definition($1::uuid)
`;

function toDefinitionResponse(row: TaskDefinitionRow) {
  return {
    id: row.id,
    brandId: row.brand_id,
    locationId: row.location_id,
    createdBy: row.created_by,
    name: row.name,
    description: row.description,
    category: row.category,
    recurrenceRule: row.recurrence_rule,
    startDate: row.start_date,
    endDate: row.end_date,
    scheduleMode: row.schedule_mode,
    // Creation accepts minute precision; PostgreSQL returns HH:mm:ss.
    scheduledTimes: row.scheduled_times.map((time) => time.slice(0, 5)),
    dueTime: row.due_time === null ? null : row.due_time.slice(0, 5),
    numericUnit: row.numeric_unit,
    // API bounds originate as finite JS numbers; arbitrary-precision input is not supported.
    numericMin: row.numeric_min === null ? null : Number(row.numeric_min),
    numericMax: row.numeric_max === null ? null : Number(row.numeric_max),
    isActive: row.is_active,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

export function createTaskDefinitionController(pool: Pool): RequestHandler {
  return async (req, res) => {
    const result = normalizeTaskDefinitionBody(req.body);
    if (!result.ok) {
      return res.status(400).json({
        error: { code: 'INVALID_BODY', message: result.message },
      });
    }
    const validated = validateTaskDefinitionBody(result.value);
    if (!validated.ok) {
      return res.status(400).json({
        error: {
          code: 'INVALID_TASK_DEFINITION',
          field: validated.field,
          message: validated.message,
        },
      });
    }
    const actorId: unknown = res.locals.actorId;
    if (typeof actorId !== 'string' || !actorId) {
      return res
        .status(401)
        .json({ error: { message: 'Authentication required' } });
    }
    const input = validated.value;
    try {
      const definition = await withUserTransaction(
        pool,
        actorId,
        async (db) => {
          const data = await db.query<TaskDefinitionRow>(
            createDefinitionQuery,
            [
              input.brandId,
              input.locationId,
              input.name,
              input.description,
              input.category,
              input.recurrenceRule,
              input.startDate,
              input.endDate,
              input.scheduleMode,
              input.scheduledTimes,
              input.dueTime,
              input.numericUnit,
              input.numericMin,
              input.numericMax,
            ],
          );
          if (data.rows.length !== 1) {
            throw new Error(
              'Definition creation did not return exactly one row',
            );
          }
          const generation = await loadManagerGenerationDefinition(
            db,
            data.rows[0].id,
          );
          // Capture the clock after database work/lock waits. Every target uses this
          // same instant, interpreted in its own timezone. Failures roll back creation.
          await generateRollingTaskInstances(db, generation, new Date());
          return toDefinitionResponse(data.rows[0]);
        },
      );
      // Only report success after the definition and initial instances COMMIT together.
      return res.status(201).json(definition);
    } catch (error) {
      const code =
        typeof error === 'object' && error !== null && 'code' in error
          ? error.code
          : undefined;
      if (code === '42501') {
        return res.status(403).json({
          error: {
            code: 'TASK_DEFINITION_FORBIDDEN',
            message:
              'You are not authorized to create a task definition for this target.',
          },
        });
      }
      if (
        ['23514', '23502', '22007', '22008', '22P02', '22003'].includes(
          String(code),
        )
      ) {
        return res.status(400).json({
          error: {
            code: 'INVALID_TASK_DEFINITION',
            message:
              'Task definition does not satisfy the database constraints.',
          },
        });
      }
      // Unexpected foreign-key failures and configuration errors remain server errors.
      throw error;
    }
  };
}

export function createTaskDefinitionDeactivateController(
  pool: Pool,
): RequestHandler {
  return async (req, res) => {
    const definitionId = req.params.id;
    if (typeof definitionId !== 'string' || !UUID_PATTERN.test(definitionId)) {
      return res.status(400).json({
        error: {
          code: 'INVALID_DEFINITION_ID',
          message: 'Task definition ID must be a UUID.',
        },
      });
    }

    const body: unknown = req.body;
    if (
      body !== undefined &&
      (typeof body !== 'object' ||
        body === null ||
        Array.isArray(body) ||
        Object.keys(body).length > 0)
    ) {
      return res.status(400).json({
        error: {
          code: 'INVALID_BODY',
          message: 'Deactivation accepts no body or an empty JSON object.',
        },
      });
    }

    const actorId: unknown = res.locals.actorId;
    if (typeof actorId !== 'string' || !actorId) {
      return res
        .status(401)
        .json({ error: { message: 'Authentication required' } });
    }

    try {
      const row = await withUserTransaction(pool, actorId, async (db) => {
        const data = await db.query<TaskDefinitionDeactivationRow>(
          deactivateDefinitionQuery,
          [definitionId],
        );
        if (data.rows.length !== 1) {
          throw new Error(
            'Definition deactivation did not return exactly one row',
          );
        }
        return data.rows[0];
      });
      return res.status(200).json({
        id: row.id,
        isActive: row.is_active,
        deactivatedAt: row.deactivated_at,
        cancelledInstanceCount: row.cancelled_instance_count,
      });
    } catch (error) {
      const code =
        typeof error === 'object' && error !== null && 'code' in error
          ? error.code
          : undefined;
      // Missing, other-organization and unauthorized definitions look the same.
      if (code === '42501') {
        return res.status(403).json({
          error: {
            code: 'TASK_DEFINITION_FORBIDDEN',
            message: 'You are not authorized to deactivate this task definition.',
          },
        });
      }
      throw error;
    }
  };
}
