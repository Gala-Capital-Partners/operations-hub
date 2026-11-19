import { describe, expect, it, vi } from 'vitest';
import type { PoolClient } from 'pg';
import type { DefinitionSchedule } from '../src/types/task-generation.js';
import {
  generationWindow,
  generateRollingTaskInstances,
  occurrenceDates,
  generateTaskInstances,
  loadManagerGenerationDefinition,
} from '../src/scheduling/generator.js';

const daily: DefinitionSchedule = {
  recurrenceRule: 'FREQ=DAILY',
  startDate: '2026-11-01',
  endDate: null,
};
const window = { from: '2026-11-03', to: '2026-11-05' };

describe('occurrenceDates', () => {
  it('includes both window boundaries', () => {
    expect(occurrenceDates(daily, window)).toEqual([
      '2026-11-03',
      '2026-11-04',
      '2026-11-05',
    ]);
  });
  it('includes a one-time date only in its window', () => {
    const def = { ...daily, recurrenceRule: null };
    expect(
      occurrenceDates(def, { from: '2026-11-01', to: '2026-11-01' }),
    ).toEqual(['2026-11-01']);
    expect(occurrenceDates(def, window)).toEqual([]);
  });
  it('clips to definition start and inclusive end', () => {
    expect(
      occurrenceDates(
        { ...daily, endDate: '2026-11-02' },
        { from: '2026-10-30', to: '2026-11-05' },
      ),
    ).toEqual(['2026-11-01', '2026-11-02']);
    expect(
      occurrenceDates({ ...daily, endDate: '2026-11-02' }, window),
    ).toEqual([]);
  });
  it('does not restart COUNT in a later window', () => {
    expect(
      occurrenceDates(
        { ...daily, recurrenceRule: 'FREQ=DAILY;COUNT=4' },
        window,
      ),
    ).toEqual(['2026-11-03', '2026-11-04']);
    expect(
      occurrenceDates(
        { ...daily, recurrenceRule: 'FREQ=DAILY;COUNT=2' },
        window,
      ),
    ).toEqual([]);
  });
  it('keeps INTERVAL anchored to the original start', () => {
    expect(
      occurrenceDates(
        { ...daily, recurrenceRule: 'FREQ=DAILY;INTERVAL=2' },
        { from: '2026-11-02', to: '2026-11-06' },
      ),
    ).toEqual(['2026-11-03', '2026-11-05']);
  });
  it('expands weekly weekdays', () => {
    expect(
      occurrenceDates(
        {
          recurrenceRule: 'FREQ=WEEKLY;BYDAY=MO,WE,FR',
          startDate: '2026-11-02',
          endDate: null,
        },
        { from: '2026-11-03', to: '2026-11-09' },
      ),
    ).toEqual(['2026-11-04', '2026-11-06', '2026-11-09']);
  });
  it('skips nonexistent month dates rather than clamping them', () => {
    expect(
      occurrenceDates(
        {
          recurrenceRule: 'FREQ=MONTHLY;BYMONTHDAY=31',
          startDate: '2026-01-31',
          endDate: null,
        },
        { from: '2026-02-01', to: '2026-03-31' },
      ),
    ).toEqual(['2026-03-31']);
  });
  it('supports month-end and leap-day rules', () => {
    expect(
      occurrenceDates(
        {
          recurrenceRule: 'FREQ=MONTHLY;BYMONTHDAY=-1',
          startDate: '2028-01-31',
          endDate: null,
        },
        { from: '2028-02-01', to: '2028-03-31' },
      ),
    ).toEqual(['2028-02-29', '2028-03-31']);
    expect(
      occurrenceDates(
        {
          recurrenceRule: 'FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29',
          startDate: '2024-02-29',
          endDate: null,
        },
        { from: '2028-02-01', to: '2028-03-01' },
      ),
    ).toEqual(['2028-02-29']);
  });
  it('keeps calendar dates contiguous across DST transitions', () => {
    expect(
      occurrenceDates(
        { ...daily, startDate: '2026-03-07' },
        { from: '2026-03-07', to: '2026-03-09' },
      ),
    ).toEqual(['2026-03-07', '2026-03-08', '2026-03-09']);
    expect(
      occurrenceDates(daily, { from: '2026-11-01', to: '2026-11-02' }),
    ).toEqual(['2026-11-01', '2026-11-02']);
  });
  it.each([
    { from: '2026-02-30', to: '2026-03-01' },
    { from: '2026-11-05', to: '2026-11-03' },
    { from: '2026-01-01', to: '2026-03-04' },
    { from: '1999-12-31', to: '2000-01-01' },
  ])('rejects invalid/unbounded windows: %j', (bad) => {
    expect(() => occurrenceDates(daily, bad)).toThrow(RangeError);
  });
  it('accepts exactly 62 inclusive dates', () => {
    expect(
      occurrenceDates(
        { ...daily, startDate: '2026-01-01' },
        { from: '2026-01-01', to: '2026-03-03' },
      ),
    ).toHaveLength(62);
  });
  it.each([
    { ...daily, recurrenceRule: 'FREQ=HOURLY' },
    { ...daily, endDate: '2026-10-01' },
    { ...daily, recurrenceRule: null, endDate: '2026-11-02' },
    { ...daily, startDate: '2026-02-30' },
  ])('rejects malformed stored definitions: %j', (bad) => {
    expect(() => occurrenceDates(bad, window)).toThrow(RangeError);
  });
});

describe('shared generation service', () => {
  const def = {
    ...daily,
    id: '22222222-2222-4222-8222-222222222222',
    version: 'token',
    targetTimezones: ['America/Los_Angeles'],
  };
  it.each(['manager', 'scheduler'] as const)(
    'uses the %s entry point with date parameters and version',
    async (mode) => {
      const query = vi.fn().mockResolvedValue({ rows: [{ inserted: 6 }] });
      const db = { query } as unknown as PoolClient;
      expect(await generateTaskInstances(db, def, window, mode)).toEqual({
        matchingDates: ['2026-11-03', '2026-11-04', '2026-11-05'],
        inserted: 6,
      });
      expect(query.mock.calls[0][0]).toContain(
        mode === 'manager'
          ? 'public.generate_task_instances'
          : 'public.scheduler_generate_task_instances',
      );
      expect(query.mock.calls[0][1]).toEqual([
        def.id,
        ['2026-11-03', '2026-11-04', '2026-11-05'],
        'token',
        null,
      ]);
    },
  );
  it('checks authorization/version even when no dates match', async () => {
    const query = vi.fn().mockResolvedValue({ rows: [{ inserted: 0 }] });
    await generateTaskInstances(
      { query } as unknown as PoolClient,
      { ...def, recurrenceRule: null },
      window,
    );
    expect(query.mock.calls[0][1]).toEqual([def.id, [], 'token', null]);
  });
  it('propagates stale-definition errors for transaction rollback', async () => {
    const error = Object.assign(new Error('stale'), { code: '40001' });
    const query = vi.fn().mockRejectedValue(error);
    await expect(
      generateTaskInstances({ query } as unknown as PoolClient, def, window),
    ).rejects.toBe(error);
    expect(query).toHaveBeenCalledTimes(1);
  });
  it('loads calendar strings and the opaque version through the authorized reader', async () => {
    const query = vi.fn().mockResolvedValue({
      rows: [
        {
          id: def.id,
          recurrence_rule: 'FREQ=DAILY',
          start_date: '2026-11-01',
          end_date: null,
          definition_version: 'token',
          target_timezones: ['America/Los_Angeles'],
        },
      ],
    });
    expect(
      await loadManagerGenerationDefinition(
        { query } as unknown as PoolClient,
        def.id,
      ),
    ).toEqual(def);
    expect(query.mock.calls[0][1]).toEqual([def.id]);
  });
});

describe('rolling local windows', () => {
  it('uses each store local day at the same instant', () => {
    const now = new Date('2026-11-18T06:00:00Z');
    expect(generationWindow(now, 'America/Los_Angeles')).toEqual({
      from: '2026-11-17',
      to: '2026-11-23',
    });
    expect(generationWindow(now, 'America/New_York')).toEqual({
      from: '2026-11-18',
      to: '2026-11-24',
    });
  });
  it.each(['2026-03-08T09:30:00Z', '2026-11-01T08:30:00Z'])(
    'adds calendar days across DST: %s',
    (instant) => {
      const window = generationWindow(new Date(instant), 'America/Los_Angeles');
      expect(
        occurrenceDates({ ...daily, startDate: '2026-01-01' }, window),
      ).toHaveLength(7);
    },
  );
  it('handles month/year boundaries and bounded catch-up', () => {
    expect(
      generationWindow(new Date('2026-12-30T12:00:00Z'), 'UTC', 2),
    ).toEqual({ from: '2026-12-28', to: '2027-01-05' });
    expect(() => generationWindow(new Date(), 'UTC', 8)).toThrow(RangeError);
    expect(() => generationWindow(new Date(), 'UTC', -1)).toThrow(RangeError);
    expect(() => generationWindow(new Date('invalid'), 'UTC')).toThrow(
      RangeError,
    );
    expect(() => generationWindow(new Date(), 'not/a/timezone')).toThrow(
      RangeError,
    );
  });
  it('restricts each brand-wide batch to its timezone, without generating past days', async () => {
    const query = vi.fn().mockResolvedValue({ rows: [{ inserted: 7 }] });
    const definition = {
      ...daily,
      id: 'def',
      version: 'token',
      targetTimezones: [
        'America/Los_Angeles',
        'America/New_York',
        'America/New_York',
      ],
    };
    expect(
      await generateRollingTaskInstances(
        { query } as unknown as PoolClient,
        definition,
        new Date('2026-11-18T06:00:00Z'),
      ),
    ).toBe(14);
    expect(query).toHaveBeenCalledTimes(2);
    expect(query.mock.calls[0][1][1]).toEqual([
      '2026-11-17',
      '2026-11-18',
      '2026-11-19',
      '2026-11-20',
      '2026-11-21',
      '2026-11-22',
      '2026-11-23',
    ]);
    expect(query.mock.calls[1][1][1][0]).toBe('2026-11-18');
    expect(query.mock.calls[1][1][1].at(-1)).toBe('2026-11-24');
    expect(query.mock.calls.map((call) => call[1][3])).toEqual(
      definition.targetTimezones.slice(0, 2),
    );
  });
  it('does not backfill before local today when the scheduler sees an earlier start date', async () => {
    const query = vi.fn().mockResolvedValue({ rows: [{ inserted: 7 }] });
    await generateRollingTaskInstances(
      { query } as unknown as PoolClient,
      { ...daily, id: 'def', version: 'token', targetTimezones: ['UTC'] },
      new Date('2026-11-18T06:00:00Z'),
      'scheduler',
    );
    const days = query.mock.calls[0][1][1];
    expect(days).toHaveLength(7);
    expect(days[0]).toBe('2026-11-18');
    expect(days.at(-1)).toBe('2026-11-24');
  });
  it('leaves future/ended definitions empty until a window overlaps', () => {
    const window = generationWindow(new Date('2026-11-18T12:00:00Z'), 'UTC');
    expect(
      occurrenceDates({ ...daily, startDate: '2026-12-01' }, window),
    ).toEqual([]);
    expect(
      occurrenceDates({ ...daily, endDate: '2026-11-17' }, window),
    ).toEqual([]);
  });
});
