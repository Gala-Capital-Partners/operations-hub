import request from 'supertest'
import { beforeEach, describe, expect, it } from 'vitest'
import { createApp } from '../src/app.js'
import { DEMO_TODAY, SEED_TASKS } from '../src/data/tasks.seed.js'
import { resetTasks } from '../src/store/task.store.js'

// Integration tests for the Tasks API. Case IDs refer to docs/QA.md.
// The store is in-memory and module-scoped, so it is reset before every test.

const app = createApp()

const validTask = { label: 'QA-Restock napkins', cat: 'Closing', date: '2026-10-09' }

async function createTask(body: Record<string, unknown> = {}) {
  const res = await request(app).post('/api/tasks').send({ ...validTask, ...body })
  expect(res.status).toBe(201)
  return res.body
}

beforeEach(() => {
  resetTasks()
})

describe('GET /api/health', () => {
  it('reports ok (API-01)', async () => {
    const res = await request(app).get('/api/health')
    expect(res.status).toBe(200)
    expect(res.body).toEqual({ status: 'ok' })
  })
})

describe('POST /api/tasks', () => {
  it('creates a task with defaults for optional fields (API-02)', async () => {
    const res = await request(app).post('/api/tasks').send(validTask)
    expect(res.status).toBe(201)
    expect(res.body).toMatchObject({
      ...validTask,
      done: false,
      time: '',
      attachments: [],
      recurrence: 'none',
      recurrenceDays: [],
    })
    expect(Number.isInteger(res.body.id)).toBe(true)
    expect(SEED_TASKS.map(t => t.id)).not.toContain(res.body.id)
  })

  it('trims the label and ignores unknown fields such as id', async () => {
    const task = await createTask({ label: '  QA-Trim me  ', id: 1, owner: 'someone' })
    expect(task.label).toBe('QA-Trim me')
    expect(task.id).not.toBe(1)
    expect(task).not.toHaveProperty('owner')
  })

  it('normalizes weekly recurrence days and drops them for other recurrences', async () => {
    const weekly = await createTask({ recurrence: 'weekly', recurrenceDays: [5, 1, 5] })
    expect(weekly.recurrenceDays).toEqual([1, 5])

    const daily = await createTask({ recurrence: 'daily', recurrenceDays: [1, 2] })
    expect(daily.recurrenceDays).toEqual([])
  })

  it.each(['label', 'cat', 'date'])('rejects a body missing %s (API-06)', async field => {
    const body: Record<string, unknown> = { ...validTask }
    delete body[field]
    const res = await request(app).post('/api/tasks').send(body)
    expect(res.status).toBe(400)
    expect(res.body.error.details).toContain(`${field} is required`)

    const list = await request(app).get('/api/tasks')
    expect(list.body).toHaveLength(SEED_TASKS.length)
  })

  it('enforces label length and content (API-07)', async () => {
    for (const label of ['', '   ', 'x'.repeat(501)]) {
      const res = await request(app).post('/api/tasks').send({ ...validTask, label })
      expect(res.status, `label of length ${label.length}`).toBe(400)
    }
    const ok = await request(app).post('/api/tasks').send({ ...validTask, label: 'x'.repeat(500) })
    expect(ok.status).toBe(201)
  })

  it.each([
    ['unsupported category (API-08)', { cat: 'Lunch' }],
    ['string instead of boolean for done (API-08)', { done: 'true' }],
    ['malformed date (API-09)', { date: '10/09/2026' }],
    ['invalid time (API-09)', { time: '25:00' }],
    ['unsupported recurrence (API-10)', { recurrence: 'monthly' }],
    ['recurrence day outside 0–6 (API-10)', { recurrence: 'weekly', recurrenceDays: [7] }],
    ['non-string attachment (API-10)', { attachments: [42] }],
  ])('rejects %s', async (_name, override) => {
    const res = await request(app).post('/api/tasks').send({ ...validTask, ...override })
    expect(res.status).toBe(400)
    expect(res.body.error.message).toBe('Invalid task')
    expect(res.body.error.details.length).toBeGreaterThan(0)
  })

  it('rejects a body that is not a JSON object', async () => {
    const res = await request(app).post('/api/tasks').send([validTask])
    expect(res.status).toBe(400)
  })

  it('rejects malformed JSON with a structured error (API-11)', async () => {
    const res = await request(app)
      .post('/api/tasks')
      .set('Content-Type', 'application/json')
      .send('{"label":')
    expect(res.status).toBe(400)
    expect(res.body.error.message).toEqual(expect.any(String))
  })
})

describe('GET /api/tasks/:id', () => {
  it('returns a created task (API-03)', async () => {
    const created = await createTask()
    const res = await request(app).get(`/api/tasks/${created.id}`)
    expect(res.status).toBe(200)
    expect(res.body).toEqual(created)
  })
})

describe('PATCH /api/tasks/:id', () => {
  it('marks a task done and preserves other fields (API-04)', async () => {
    const created = await createTask({ time: '21:00', attachments: ['checklist.pdf'] })
    const res = await request(app).patch(`/api/tasks/${created.id}`).send({ done: true })
    expect(res.status).toBe(200)
    expect(res.body).toEqual({ ...created, done: true })

    const fetched = await request(app).get(`/api/tasks/${created.id}`)
    expect(fetched.body.done).toBe(true)
  })

  it('clears recurrence days when switching away from weekly', async () => {
    const created = await createTask({ recurrence: 'weekly', recurrenceDays: [1, 3] })
    const res = await request(app).patch(`/api/tasks/${created.id}`).send({ recurrence: 'daily' })
    expect(res.status).toBe(200)
    expect(res.body.recurrenceDays).toEqual([])
  })

  it('does not let the body change the id', async () => {
    const created = await createTask()
    const res = await request(app).patch(`/api/tasks/${created.id}`).send({ id: 999, done: true })
    expect(res.status).toBe(200)
    expect(res.body.id).toBe(created.id)
  })

  it('rejects an empty body (API-11)', async () => {
    const created = await createTask()
    const res = await request(app).patch(`/api/tasks/${created.id}`).send({})
    expect(res.status).toBe(400)
    expect(res.body.error.message).toBe('Invalid task update')
  })

  it('rejects invalid field values without changing the task', async () => {
    const created = await createTask()
    const res = await request(app).patch(`/api/tasks/${created.id}`).send({ done: 'yes' })
    expect(res.status).toBe(400)

    const fetched = await request(app).get(`/api/tasks/${created.id}`)
    expect(fetched.body).toEqual(created)
  })
})

describe('DELETE /api/tasks/:id', () => {
  it('deletes a task, then it is gone (API-05)', async () => {
    const created = await createTask()
    const res = await request(app).delete(`/api/tasks/${created.id}`)
    expect(res.status).toBe(204)
    expect(res.text).toBe('')

    expect((await request(app).get(`/api/tasks/${created.id}`)).status).toBe(404)
    expect((await request(app).delete(`/api/tasks/${created.id}`)).status).toBe(404)
  })
})

describe('task id handling', () => {
  const methods = [
    ['GET', (id: string) => request(app).get(`/api/tasks/${id}`)],
    ['PATCH', (id: string) => request(app).patch(`/api/tasks/${id}`).send({ done: true })],
    ['DELETE', (id: string) => request(app).delete(`/api/tasks/${id}`)],
  ] as const

  for (const [method, send] of methods) {
    it.each(['abc', '0', '-1', '1.5'])(`${method} rejects id %s with 400 (API-12)`, async id => {
      const res = await send(id)
      expect(res.status).toBe(400)
      expect(res.body.error.message).toBe('id must be a positive integer')
    })

    it(`${method} returns 404 for an absent id (API-13)`, async () => {
      const res = await send('99999')
      expect(res.status).toBe(404)
      expect(res.body.error.message).toEqual(expect.any(String))
    })
  }
})

describe('GET /api/tasks filters (API-14, API-15)', () => {
  beforeEach(async () => {
    // Fixtures before, on and after the range boundaries used below.
    await createTask({ label: 'QA-before', date: '2026-10-08', cat: 'Opening' })
    await createTask({ label: 'QA-from', date: '2026-10-09', cat: 'Opening', done: true })
    await createTask({ label: 'QA-middle', date: '2026-10-10', cat: 'Midday' })
    await createTask({ label: 'QA-to', date: '2026-10-11', cat: 'Closing', done: true })
    await createTask({ label: 'QA-after', date: '2026-10-12', cat: 'Closing' })
  })

  const labels = (body: { label: string }[]) => body.map(t => t.label)

  it('returns every task, sorted by date then time, without filters', async () => {
    const res = await request(app).get('/api/tasks')
    expect(res.status).toBe(200)
    expect(res.body).toHaveLength(SEED_TASKS.length + 5)
    const keys = res.body.map((t: { date: string; time: string }) => `${t.date} ${t.time}`)
    expect(keys).toEqual([...keys].sort())
  })

  it('filters by exact date', async () => {
    const res = await request(app).get('/api/tasks').query({ date: '2026-10-10' })
    expect(labels(res.body)).toEqual(['QA-middle'])
  })

  it('includes both range boundaries', async () => {
    const res = await request(app).get('/api/tasks').query({ from: '2026-10-09', to: '2026-10-11' })
    expect(labels(res.body)).toEqual(['QA-from', 'QA-middle', 'QA-to'])
  })

  it('filters by category and completion state, separately and together', async () => {
    const opening = await request(app).get('/api/tasks').query({ cat: 'Opening', from: '2026-10-01' })
    expect(labels(opening.body)).toEqual(['QA-before', 'QA-from'])

    const done = await request(app).get('/api/tasks').query({ done: 'true', from: '2026-10-01' })
    expect(labels(done.body)).toEqual(['QA-from', 'QA-to'])

    const both = await request(app).get('/api/tasks').query({ cat: 'Closing', done: 'false', from: '2026-10-01' })
    expect(labels(both.body)).toEqual(['QA-after'])
  })

  it('rejects an invalid category', async () => {
    const res = await request(app).get('/api/tasks').query({ cat: 'Lunch' })
    expect(res.status).toBe(400)
    expect(res.body.error.message).toEqual(expect.any(String))
  })
})

describe('POST /api/tasks/reset', () => {
  it('restores the seed data (API-17)', async () => {
    await createTask()
    await request(app).delete('/api/tasks/1')

    const res = await request(app).post('/api/tasks/reset')
    expect(res.status).toBe(200)
    expect(res.body).toHaveLength(SEED_TASKS.length)
    expect(res.body.every((t: { date: string }) => t.date <= DEMO_TODAY)).toBe(true)
    expect((await request(app).get('/api/tasks/1')).status).toBe(200)
  })
})

describe('unknown routes', () => {
  it('return a structured 404 (API-16)', async () => {
    const res = await request(app).get('/api/nope')
    expect(res.status).toBe(404)
    expect(res.body).toEqual({ error: { message: expect.any(String) } })
  })
})
