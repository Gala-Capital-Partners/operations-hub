import { describe, expect, it, vi } from 'vitest';
import type { Pool } from 'pg';
import type { Request, Response } from 'express';
import { createTaskDefinitionDeactivateController } from '../src/controller/task-definitions.controller.js';

// Exercises the controller and transaction wrapper with a substituted client.
// Cancellation rules and authorization are covered by
// supabase/tests/task_definition_deactivation_verification.sql.
const DEFINITION_ID = '33333333-3333-4333-8333-333333333333';
const DEACTIVATED_AT = new Date('2026-11-25T18:00:00Z');

function fixture(
  options: {
    id?: string;
    body?: unknown;
    error?: Error & { code?: string };
    count?: number;
  } = {},
) {
  const query = vi.fn(async (sql: string, _values?: unknown[]) => {
    if (sql.includes('public.deactivate_task_definition')) {
      if (options.error) throw options.error;
      return {
        rows: [
          {
            id: DEFINITION_ID,
            is_active: false,
            deactivated_at: DEACTIVATED_AT,
            cancelled_instance_count: options.count ?? 5,
          },
        ],
      };
    }
    return { rows: [] };
  });
  const release = vi.fn();
  const pool = {
    connect: vi.fn().mockResolvedValue({ query, release }),
  } as unknown as Pool;
  const req = {
    params: { id: options.id ?? DEFINITION_ID },
    body: options.body,
  } as unknown as Request;
  const res = { locals: { actorId: 'actor' }, status: vi.fn(), json: vi.fn() };
  res.status.mockReturnValue(res);
  return {
    query,
    pool,
    req,
    res,
    run: () =>
      createTaskDefinitionDeactivateController(pool)(
        req,
        res as unknown as Response,
        vi.fn(),
      ),
  };
}

describe('task definition deactivation', () => {
  it('deactivates in one transaction and reports the cancelled count', async () => {
    const f = fixture();
    await f.run();
    expect(f.res.status).toHaveBeenCalledWith(200);
    expect(f.res.json).toHaveBeenCalledWith({
      id: DEFINITION_ID,
      isActive: false,
      deactivatedAt: DEACTIVATED_AT,
      cancelledInstanceCount: 5,
    });
    const calls = f.query.mock.calls;
    expect(calls[0][0]).toBe('BEGIN');
    expect(calls.at(-1)![0]).toBe('COMMIT');
    const call = calls.find(([sql]) =>
      sql.includes('public.deactivate_task_definition'),
    )!;
    expect(call[1]).toEqual([DEFINITION_ID]);
  });

  it('returns 200 with a zero count when already inactive', async () => {
    const f = fixture({ count: 0, body: {} });
    await f.run();
    expect(f.res.status).toHaveBeenCalledWith(200);
    expect(f.res.json).toHaveBeenCalledWith(
      expect.objectContaining({ isActive: false, cancelledInstanceCount: 0 }),
    );
  });

  it('rejects a non-UUID id without touching the database', async () => {
    const f = fixture({ id: 'not-a-uuid' });
    await f.run();
    expect(f.res.status).toHaveBeenCalledWith(400);
    expect(f.pool.connect).not.toHaveBeenCalled();
  });

  it('rejects a non-empty body', async () => {
    const f = fixture({ body: { cancelToday: true } });
    await f.run();
    expect(f.res.status).toHaveBeenCalledWith(400);
    expect(f.pool.connect).not.toHaveBeenCalled();
  });

  it('maps missing or unauthorized definitions to 403 and rolls back', async () => {
    const error = Object.assign(new Error('not authorized'), { code: '42501' });
    const f = fixture({ error });
    await f.run();
    expect(f.res.status).toHaveBeenCalledWith(403);
    expect(f.res.json).toHaveBeenCalledWith({
      error: {
        code: 'TASK_DEFINITION_FORBIDDEN',
        message: expect.any(String),
      },
    });
    expect(f.query.mock.calls.at(-1)![0]).toBe('ROLLBACK');
  });

  it('rethrows unexpected database errors', async () => {
    const f = fixture({ error: new Error('connection lost') });
    await expect(f.run()).rejects.toThrow('connection lost');
    expect(f.res.json).not.toHaveBeenCalled();
  });
});
