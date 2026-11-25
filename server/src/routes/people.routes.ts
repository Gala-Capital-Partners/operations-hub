import { Router, type ErrorRequestHandler, type RequestHandler } from 'express'
import type { Pool } from 'pg'
import { createPeopleController, type DeliverInvitation } from '../controller/people.controller.js'
import { isUuid } from '../validation/uuid.js'

export function createPeopleRouter({ pool, requireAuth, deliver }: {
  pool: Pool
  requireAuth: RequestHandler
  deliver?: DeliverInvitation
}) {
  const router = Router()
  const controller = createPeopleController(pool, deliver)
  router.param('locationId', (_req, res, next, value) => {
    if (!isUuid(value)) return res.status(400).json({ error: { message: 'Invalid location ID.' } })
    next()
  })

  router.post('/locations/:locationId/invitations', requireAuth, controller.inviteEmployee)
  router.get('/locations/:locationId/invitations', requireAuth, controller.listInvitations)
  router.post('/invitations/accept', requireAuth, controller.acceptInvitation)
  router.delete('/locations/:locationId/invitations/:id', requireAuth, controller.cancelInvitation)
  router.delete('/locations/:locationId/members/:userId', requireAuth, controller.removeMember)

  const handleError: ErrorRequestHandler = (err, _req, res, next) => {
    if (err.code === '22023') return res.status(400).json({ error: { message: 'Invalid request parameters.' } })
    if (err.code === '42501') return res.status(403).json({ error: { message: 'Access denied.' } })
    if (err.code === '55000') return res.status(409).json({ error: { message: 'The invitation or assignment is unavailable.' } })
    next(err)
  }
  router.use(handleError)
  return router
}
