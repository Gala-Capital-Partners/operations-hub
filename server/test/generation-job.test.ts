import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Pool } from 'pg';
import type { GenerationDefinition } from '../src/types/task-generation.js';
import { runGenerationJob, main } from '../src/jobs/generate-task-instances.js';
import {
  loadSchedulerGenerationDefinitions,
  generateRollingTaskInstances,
} from '../src/scheduling/generator.js';

vi.mock('../src/scheduling/generator.js', () => ({
  loadSchedulerGenerationDefinitions: vi.fn(),
  generateRollingTaskInstances: vi.fn(),
}));
const load = vi.mocked(loadSchedulerGenerationDefinitions);
const generate = vi.mocked(generateRollingTaskInstances);
const def: GenerationDefinition = {
  id: 'a',
  version: 'old',
  recurrenceRule: 'FREQ=DAILY',
  startDate: '2026-11-01',
  endDate: null,
  targetTimezones: ['UTC'],
};
const stale = () =>
  Object.assign(new Error('private credentials'), { code: '40001' });
const logger = { info: vi.fn(), warn: vi.fn(), error: vi.fn() };
function fixture() {
  const query = vi.fn().mockResolvedValue({ rows: [] });
  const release = vi.fn();
  const client = { query, release };
  const pool = {
    connect: vi.fn().mockResolvedValue(client),
    end: vi.fn().mockResolvedValue(undefined),
    on: vi.fn(),
    off: vi.fn(),
  };
  return { pool: pool as unknown as Pool, query, release, raw: pool, client };
}
beforeEach(() => {
  vi.resetAllMocks();
  load.mockResolvedValue([def]);
  generate.mockResolvedValue(7);
});
afterEach(() => vi.restoreAllMocks());

describe('generation job', () => {
  it('does not start database work on import', () => {
    expect(load).not.toHaveBeenCalled();
    expect(generate).not.toHaveBeenCalled();
  });
  it('commits each definition and reports counts with zero catch-up', async () => {
    const f = fixture();
    const now = new Date('2026-11-18T12:00:00Z');
    const summary = await runGenerationJob(f.pool, { logger, now: () => now });
    expect(summary).toEqual({
      processed: 1,
      succeeded: 1,
      skipped: 0,
      inserted: 7,
      failed: 0,
    });
    expect(generate).toHaveBeenCalledWith(f.client, def, now, 'scheduler', 0);
    expect(f.query.mock.calls.map((call) => call[0])).toEqual([
      'BEGIN',
      'SET LOCAL ROLE operations_hub_scheduler',
      'COMMIT',
      'BEGIN',
      'SET LOCAL ROLE operations_hub_scheduler',
      'COMMIT',
    ]);
    expect(f.release).toHaveBeenCalledTimes(2);
    expect(logger.info).toHaveBeenCalledTimes(1);
  });
  it.each([
    [new RangeError('private input'), 'INVALID_GENERATION_INPUT'],
    [Object.assign(new Error('private input'), { code: 'ECONNREFUSED' }), 'ECONNREFUSED'],
    [Object.assign(new Error('private input'), { code: 'ETIMEDOUT' }), 'ETIMEDOUT'],
    [Object.assign(new Error('private input'), { code: 'untrusted-detail' }), 'UNKNOWN'],
  ] as const)('logs only the safe failure category (%s)', async (error, category) => {
    generate.mockRejectedValueOnce(error);
    const summary = await runGenerationJob(fixture().pool, { logger });
    expect(summary.failed).toBe(1);
    expect(logger.error.mock.calls).toEqual([
      [`Task generation failed definition=a attempts=1 code=${category}`],
    ]);
  });
  it('handles an empty list', async () => {
    load.mockResolvedValue([]);
    expect((await runGenerationJob(fixture().pool, { logger })).processed).toBe(
      0,
    );
    expect(generate).not.toHaveBeenCalled();
  });
  it('rolls back and reloads the changed version in a new transaction', async () => {
    const f = fixture();
    const updated = { ...def, version: 'new' };
    load.mockResolvedValueOnce([def]).mockResolvedValueOnce([updated]);
    generate.mockRejectedValueOnce(stale()).mockResolvedValueOnce(7);
    expect((await runGenerationJob(f.pool, { logger })).failed).toBe(0);
    expect(generate.mock.calls[1][1]).toEqual(updated);
    expect(f.query.mock.calls.map((call) => call[0])).toEqual([
      'BEGIN',
      'SET LOCAL ROLE operations_hub_scheduler',
      'COMMIT',
      'BEGIN',
      'SET LOCAL ROLE operations_hub_scheduler',
      'ROLLBACK',
      'BEGIN',
      'SET LOCAL ROLE operations_hub_scheduler',
      'COMMIT',
    ]);
    expect(logger.warn).toHaveBeenCalledTimes(1);
  });
  it('stops after three attempts and continues with other definitions', async () => {
    load.mockResolvedValue([def, { ...def, id: 'b' }]);
    generate
      .mockRejectedValueOnce(stale())
      .mockRejectedValueOnce(stale())
      .mockRejectedValueOnce(stale())
      .mockResolvedValueOnce(7);
    expect(await runGenerationJob(fixture().pool, { logger })).toEqual({
      processed: 2,
      succeeded: 1,
      skipped: 0,
      inserted: 7,
      failed: 1,
    });
    expect(generate).toHaveBeenCalledTimes(4);
    expect(JSON.stringify(logger.error.mock.calls)).not.toContain(
      'private credentials',
    );
  });
  it('skips definitions no longer eligible on retry', async () => {
    load.mockResolvedValueOnce([def]).mockResolvedValueOnce([]);
    generate.mockRejectedValueOnce(stale());
    expect((await runGenerationJob(fixture().pool, { logger })).skipped).toBe(
      1,
    );
    expect(generate).toHaveBeenCalledTimes(1);
  });
  it('does not retry other errors and discards a connection if rollback fails', async () => {
    const f = fixture();
    f.query.mockImplementation(async (sql: string) => {
      if (sql === 'ROLLBACK') throw new Error('connection lost');
      return { rows: [] };
    });
    generate.mockRejectedValue(
      Object.assign(new Error('secret'), { code: '42501' }),
    );
    expect((await runGenerationJob(f.pool, { logger })).failed).toBe(1);
    expect(generate).toHaveBeenCalledTimes(1);
    expect(f.release).toHaveBeenLastCalledWith(true);
  });
  it('returns a failure exit code and closes the pool on partial failure', async () => {
    vi.spyOn(console, 'info').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    const f = fixture();
    generate.mockRejectedValue(new Error('failure'));
    expect(await main(f.pool)).toBe(1);
    expect(f.raw.end).toHaveBeenCalledTimes(1);
    expect(f.raw.off).toHaveBeenCalledWith('error', expect.any(Function));
  });
  it('closes the pool when the initial listing fails', async () => {
    const f = fixture();
    load.mockRejectedValue(new Error('cannot list'));
    await expect(main(f.pool)).rejects.toThrow('cannot list');
    expect(f.raw.end).toHaveBeenCalledTimes(1);
  });
  it('returns zero on success', async () => {
    vi.spyOn(console, 'info').mockImplementation(() => {});
    expect(await main(fixture().pool)).toBe(0);
  });
});
