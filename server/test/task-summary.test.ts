import request from 'supertest'
import type { RequestHandler } from 'express'
import type { Pool } from 'pg'
import { describe, expect, it } from 'vitest'
import { createApp } from '../src/app.js'

// Route-level tests for GET /api/task-instances/summary with a fake pool.
// Scoping itself is enforced in PostgreSQL and covered by
// supabase/tests/task_summary_verification.sql.

const ACTOR = '11111111-1111-4111-8111-111111111111'

type Call = { sql: string; params?: unknown[] }

function fakePool(summaryRows: unknown[] = []) {
  const calls: Call[] = []
  let released = 0
  const client = {
    async query(sql: string, params?: unknown[]) {
      calls.push({ sql, params })
      if (sql.includes('task_instances.read')) return { rows: summaryRows }
      return { rows: [] }
    },
    release() {
      released += 1
    },
  }
  const pool = { connect: async () => client } as unknown as Pool
  return { pool, calls, released: () => released }
}

// Accepts any bearer token and uses a fixed verified actor.
const fakeAuth: RequestHandler = (req, res, next) => {
  if (!req.get('authorization')) {
    res.status(401).json({ error: { message: 'Authentication required' } })
    return
  }
  res.locals.actorId = ACTOR
  next()
}

function app(rows: unknown[] = []) {
  const db = fakePool(rows)
  return { app: createApp({ pool: db.pool, requireAuth: fakeAuth }), db }
}

const rows = [
  {
    location_id: 'loc-a', location_name: 'Downtown', store_number: '101', timezone: 'America/Los_Angeles',
    brand_id: 'brand-1', brand_name: 'BurgerCraft', total: 5, completed: 3,
  },
  {
    location_id: 'loc-b', location_name: 'Harbor View', store_number: null, timezone: 'America/Los_Angeles',
    brand_id: 'brand-2', brand_name: 'Taco Verde', total: 0, completed: 0,
  },
]

describe('GET /api/task-instances/summary', () => {
  it('requires authentication', async () => {
    const { app: server, db } = app()
    const res = await request(server).get('/api/task-instances/summary').query({ date: '2026-11-19' })
    expect(res.status).toBe(401)
    expect(db.calls).toHaveLength(0)
  })

  it.each([
    ['missing', undefined],
    ['malformed', '11/19/2026'],
    ['impossible', '2026-02-30'],
    ['out of range', '1999-12-31'],
  ])('rejects a %s date with 400', async (_name, date) => {
    const { app: server, db } = app()
    const res = await request(server)
      .get('/api/task-instances/summary')
      .set('Authorization', 'Bearer token')
      .query(date === undefined ? {} : { date })
    expect(res.status).toBe(400)
    expect(res.body.error.code).toBe('INVALID_DATE')
    expect(db.calls).toHaveLength(0)
  })

  it('rejects a repeated date parameter', async () => {
    const { app: server } = app()
    const res = await request(server)
      .get('/api/task-instances/summary?date=2026-11-19&date=2026-11-20')
      .set('Authorization', 'Bearer token')
    expect(res.status).toBe(400)
  })

  it('runs the query as the verified user inside one transaction', async () => {
    const { app: server, db } = app(rows)
    const res = await request(server)
      .get('/api/task-instances/summary')
      .set('Authorization', 'Bearer token')
      .query({ date: '2026-11-19' })
    expect(res.status).toBe(200)

    const sql = db.calls.map(c => c.sql.trim())
    expect(sql[0]).toBe('BEGIN')
    expect(sql[1]).toBe('SET LOCAL ROLE operations_hub_runtime')
    expect(db.calls[2].params).toEqual([ACTOR])
    expect(db.calls[3].params).toEqual(['2026-11-19'])
    expect(sql.at(-1)).toBe('COMMIT')
    expect(db.released()).toBe(1)
  })

  it('returns per-location counts and totals, including locations with no tasks', async () => {
    const { app: server } = app(rows)
    const res = await request(server)
      .get('/api/task-instances/summary')
      .set('Authorization', 'Bearer token')
      .query({ date: '2026-11-19' })
    expect(res.body).toEqual({
      date: '2026-11-19',
      totals: { locations: 2, locationsWithoutTasks: 1, total: 5, completed: 3, remaining: 2 },
      locations: [
        {
          locationId: 'loc-a', locationName: 'Downtown', storeNumber: '101', timezone: 'America/Los_Angeles',
          brandId: 'brand-1', brandName: 'BurgerCraft', total: 5, completed: 3, remaining: 2,
        },
        {
          locationId: 'loc-b', locationName: 'Harbor View', storeNumber: null, timezone: 'America/Los_Angeles',
          brandId: 'brand-2', brandName: 'Taco Verde', total: 0, completed: 0, remaining: 0,
        },
      ],
    })
  })

  it('returns empty totals when the user can read no locations', async () => {
    const { app: server } = app([])
    const res = await request(server)
      .get('/api/task-instances/summary')
      .set('Authorization', 'Bearer token')
      .query({ date: '2026-11-19' })
    expect(res.status).toBe(200)
    expect(res.body).toEqual({
      date: '2026-11-19',
      totals: { locations: 0, locationsWithoutTasks: 0, total: 0, completed: 0, remaining: 0 },
      locations: [],
    })
  })
})
