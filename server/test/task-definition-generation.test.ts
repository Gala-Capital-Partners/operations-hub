import { afterEach, describe, expect, it, vi } from 'vitest';
import type { Pool } from 'pg';
import type { Request, Response } from 'express';
import { createTaskDefinitionController } from '../src/controller/task-definitions.controller.js';

// Exercise the real controller, generation service and transaction wrapper.
// Only the PostgreSQL client is substituted; SQL authorization is tested separately.
afterEach(() => vi.useRealTimers());

function fixture(failGeneration = false, startDate = '2026-11-01') {
  const body = {
    brandId: '11111111-1111-4111-8111-111111111111',
    locationId: '22222222-2222-4222-8222-222222222222',
    name: 'Check freezer',
    description: '',
    category: 'Opening',
    startDate,
    recurrenceRule: 'FREQ=DAILY',
  };
  const row = {
    id: '33333333-3333-4333-8333-333333333333',
    brand_id: body.brandId,
    location_id: body.locationId,
    created_by: 'actor',
    name: body.name,
    description: '',
    category: 'Opening',
    recurrence_rule: 'FREQ=DAILY',
    start_date: startDate,
    end_date: null,
    schedule_mode: 'all_day',
    scheduled_times: [],
    due_time: null,
    numeric_unit: null,
    numeric_min: null,
    numeric_max: null,
    is_active: true,
    created_at: new Date(),
    updated_at: new Date(),
  };
  const query = vi.fn(async (sql: string, _values?: unknown[]) => {
    if (sql.includes('public.create_task_definition')) return { rows: [row] };
    if (sql.includes('public.task_definition_generation_input'))
      return {
        rows: [
          {
            id: row.id,
            recurrence_rule: row.recurrence_rule,
            start_date: startDate,
            end_date: null,
            definition_version: 'version',
            target_timezones: ['America/Los_Angeles'],
          },
        ],
      };
    if (sql.includes('public.generate_task_instances')) {
      if (failGeneration) throw new Error('generation unavailable');
      return { rows: [{ inserted: 7 }] };
    }
    return { rows: [] };
  });
  const release = vi.fn();
  const pool = {
    connect: vi.fn().mockResolvedValue({ query, release }),
  } as unknown as Pool;
  const req = { body } as Request;
  const res = { locals: { actorId: 'actor' }, status: vi.fn(), json: vi.fn() };
  res.status.mockReturnValue(res);
  return {
    query,
    release,
    req,
    res,
    controller: createTaskDefinitionController(pool),
  };
}

describe('definition creation with initial generation', () => {
  it('generates in the creation transaction and responds only after commit', async () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date('2026-11-18T06:00:00Z'));
    const f = fixture();
    await f.controller(f.req, f.res as unknown as Response, vi.fn());
    expect(f.res.status).toHaveBeenCalledWith(201);
    const calls = f.query.mock.calls;
    expect(calls[0][0]).toBe('BEGIN');
    expect(calls.at(-1)![0]).toBe('COMMIT');
    const generation = calls.find(([sql]) =>
      sql.includes('public.generate_task_instances'),
    )!;
    expect(generation[1]).toEqual([
      '33333333-3333-4333-8333-333333333333',
      [
        '2026-11-17',
        '2026-11-18',
        '2026-11-19',
        '2026-11-20',
        '2026-11-21',
        '2026-11-22',
        '2026-11-23',
      ],
      'version',
      'America/Los_Angeles',
    ]);
    expect(f.query.mock.invocationCallOrder.at(-1)).toBeLessThan(
      f.res.json.mock.invocationCallOrder[0],
    );
    expect(f.release).toHaveBeenCalledWith(false);
  });
  it('rolls back creation and sends no success when generation fails', async () => {
    const f = fixture(true);
    await expect(
      f.controller(f.req, f.res as unknown as Response, vi.fn()),
    ).rejects.toThrow('generation unavailable');
    expect(f.query.mock.calls.at(-1)![0]).toBe('ROLLBACK');
    expect(f.query.mock.calls.some(([sql]) => sql === 'COMMIT')).toBe(false);
    expect(f.res.json).not.toHaveBeenCalled();
    expect(f.release).toHaveBeenCalledWith(false);
  });
  it('allows future definitions with no initial occurrences', async () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date('2026-11-18T06:00:00Z'));
    const f = fixture(false, '2026-12-01');
    await f.controller(f.req, f.res as unknown as Response, vi.fn());
    expect(f.res.status).toHaveBeenCalledWith(201);
    const call = f.query.mock.calls.find(([sql]) =>
      sql.includes('public.generate_task_instances'),
    )!;
    expect(call[1]![1]).toEqual([]);
  });
});
