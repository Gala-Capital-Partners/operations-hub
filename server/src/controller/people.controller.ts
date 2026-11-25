import { randomUUID } from 'node:crypto'
import type { RequestHandler } from 'express'
import type { Pool } from 'pg'
import { createAuthClient } from '../auth/bearer-token.js'
import { queryAsUser } from '../db/transaction.js'
import { isUuid } from '../validation/uuid.js'

export type DeliverInvitation = (email: string, redirect: URL) => Promise<void>

async function deliverInvitation(email: string, redirect: URL) {
  const { error } = await createAuthClient().auth.signInWithOtp({
    email, options: { emailRedirectTo: redirect.toString() },
  })
  if (error) throw new Error('Invitation email delivery failed')
}

function onlyFields(body: unknown, fields: string[]): boolean {
  return !!body && typeof body === 'object' && !Array.isArray(body) &&
    Object.keys(body).every(key => fields.includes(key))
}

export function createPeopleController(pool: Pool, deliver: DeliverInvitation = deliverInvitation) {
  const inviteEmployee: RequestHandler = async (req, res) => {
    const email = typeof req.body?.email === 'string' ? req.body.email.trim().toLowerCase() : ''
    if (!onlyFields(req.body, ['email']) || email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      return res.status(400).json({ error: { message: 'Provide an employee email address.' } })
    }
    let redirect: URL
    try {
      redirect = new URL(process.env.INVITATION_ACCEPT_URL ?? '')
      if (!['https:', 'http:'].includes(redirect.protocol)) throw new Error('Invalid protocol')
    } catch {
      return res.status(500).json({ error: { message: 'Invitation acceptance URL is not configured correctly.' } })
    }
    const { rows: [invite] } = await queryAsUser(pool, res.locals.actorId,
      'SELECT id, token, expires_at FROM identity_access.invite_store_employee($1,$2)', [req.params.locationId, email])
    // Commit before sending. On delivery failure the manager can retry or cancel this ID.
    try {
      redirect.searchParams.set('invitation', invite.token)
      await deliver(email, redirect)
    } catch {
      return res.status(503).json({ invitationId: invite.id, error: { message: 'Could not send the invitation. Retry or cancel it.' } })
    }
    return res.status(201).json({ id: invite.id, expiresAt: invite.expires_at })
  }

  const listInvitations: RequestHandler = async (req, res) => {
    const { rows } = await queryAsUser(pool, res.locals.actorId,
      'SELECT id, email, expires_at AS "expiresAt" FROM identity_access.pending_store_invitations($1)',
      [req.params.locationId])
    return res.json({ invitations: rows })
  }

  const acceptInvitation: RequestHandler = async (req, res) => {
    const { token, fullName } = req.body ?? {}
    if (!onlyFields(req.body, ['token', 'fullName']) || !isUuid(token) ||
        typeof fullName !== 'string' || !fullName.trim() || [...fullName.trim()].length > 200) {
      return res.status(400).json({ error: { message: 'Provide an invitation token and full name.' } })
    }
    if (!res.locals.verifiedEmail) return res.status(403).json({ error: { message: 'A confirmed email is required.' } })
    const { rows: [row] } = await queryAsUser(pool, res.locals.actorId,
      'SELECT identity_access.accept_store_invitation($1,$2,$3) AS location_id',
      [token, res.locals.verifiedEmail, fullName.trim()])
    return res.json({ locationId: row.location_id })
  }

  const cancelInvitation: RequestHandler = async (req, res) => {
    if (!isUuid(req.params.id)) return res.status(400).json({ error: { message: 'Invalid invitation ID.' } })
    await queryAsUser(pool, res.locals.actorId, 'SELECT identity_access.cancel_store_invitation($1,$2)',
      [req.params.locationId, req.params.id])
    return res.sendStatus(204)
  }

  const removeMember: RequestHandler = async (req, res) => {
    if (!isUuid(req.params.userId)) return res.status(400).json({ error: { message: 'Invalid user ID.' } })
    await queryAsUser(pool, res.locals.actorId, 'SELECT identity_access.remove_invited_member($1,$2,$3)',
      [req.params.userId, req.params.locationId, randomUUID()])
    return res.sendStatus(204)
  }

  return { inviteEmployee, listInvitations, acceptInvitation, cancelInvitation, removeMember }
}
