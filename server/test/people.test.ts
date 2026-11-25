import express from 'express'
import type { Pool } from 'pg'
import request from 'supertest'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { createPeopleRouter } from '../src/routes/people.routes.js'

const id = '00000000-0000-4000-8000-000000000001'
const token = '00000000-0000-4000-8000-000000000002'
const path = `/api/locations/${id}/invitations`

beforeEach(() => vi.stubEnv('INVITATION_ACCEPT_URL', 'https://app.example.test/accept'))
afterEach(() => { vi.unstubAllEnvs() })

function setup() {
  const query = vi.fn(async () => ({ rows: [{ id, token, expires_at: '2026-12-01', location_id: id }] }))
  const pool = { connect: async () => ({ query, release() {} }) } as unknown as Pool
  const deliver = vi.fn(async (_email: string, _redirect: URL) => {})
  const app = express()
  app.use(express.json())
  app.use('/api', createPeopleRouter({ pool, deliver, requireAuth(req, res, next) {
    if (!req.headers.authorization) return void res.sendStatus(401)
    res.locals.actorId = id
    res.locals.verifiedEmail = 'recipient@example.test'
    next()
  } }))
  return { app, query, deliver }
}

it('commits the invitation before delivery and exposes only its management ID', async () => {
  const { app, deliver, query } = setup()
  deliver.mockImplementationOnce(async () => {
    expect(query).toHaveBeenLastCalledWith('COMMIT')
  })
  const res = await request(app).post(path).set('Authorization','Bearer test').send({ email: ' Person@Example.Test ' })
  expect(res.status).toBe(201)
  expect(res.body).toEqual({ id, expiresAt: '2026-12-01' })
  expect(deliver).toHaveBeenCalledWith('person@example.test', new URL(`https://app.example.test/accept?invitation=${token}`))
})

it('reports delivery failure with a cancellable ID and no acceptance token', async () => {
  const { app, deliver } = setup()
  deliver.mockRejectedValueOnce(new Error('provider failure'))
  const res = await request(app).post(path).set('Authorization','Bearer test').send({ email: 'person@example.test' })
  expect(res.status).toBe(503)
  expect(res.body.invitationId).toBe(id)
  expect(res.text).not.toContain(token)
})

it('requires sign-in and rejects caller-supplied role and identity', async () => {
  const { app, query } = setup()
  await request(app).post(path).send({ email: 'person@example.test' }).expect(401)
  await request(app).post(path).set('Authorization','Bearer test').send({ email: 'person@example.test', role:'org_admin' }).expect(400)
  await request(app).post('/api/invitations/accept').set('Authorization','Bearer test').send({ token, fullName:'Name',email:'other@example.test' }).expect(400)
  expect(query).not.toHaveBeenCalled()
})

it('accepts using the verified email from authentication', async () => {
  const { app, query } = setup()
  await request(app).post('/api/invitations/accept').set('Authorization','Bearer test')
    .send({ token, fullName:' New Employee ' }).expect(200, { locationId:id })
  expect(query).toHaveBeenCalledWith(expect.stringContaining('accept_store_invitation'),[token,'recipient@example.test','New Employee'])
})

it.each(['', 'invalid', 'file:///tmp/accept'])('rejects invalid redirect configuration before writing', async value => {
  vi.stubEnv('INVITATION_ACCEPT_URL', value)
  const { app, query, deliver } = setup()
  await request(app).post(path).set('Authorization', 'Bearer test').send({ email: 'person@example.test' }).expect(500)
  expect(query).not.toHaveBeenCalled()
  expect(deliver).not.toHaveBeenCalled()
})

it.each([['42501', 403], ['55000', 409], ['22023', 400]] as const)('maps database error %s', async (code, status) => {
  const { app, query } = setup()
  query.mockRejectedValueOnce(Object.assign(new Error('database error'), { code }))
  await request(app).get(path).set('Authorization', 'Bearer test').expect(status)
})

it('routes invitation cancellation and membership removal to their respective writers', async () => {
  const { app, query } = setup()
  await request(app).delete(`${path}/${token}`).set('Authorization', 'Bearer test').expect(204)
  expect(query).toHaveBeenCalledWith(expect.stringContaining('cancel_store_invitation'), [id, token])
  await request(app).delete(`/api/locations/${id}/members/${token}`).set('Authorization', 'Bearer test').expect(204)
  expect(query).toHaveBeenCalledWith(expect.stringContaining('remove_invited_member'), [token, id, expect.any(String)])
})
