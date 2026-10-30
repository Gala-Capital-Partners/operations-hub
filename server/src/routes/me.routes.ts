import { Router, type RequestHandler } from 'express';
import { Pool } from 'pg';
import { createGetMeController } from '../controller/me.controller.js';

/**
 * GET /api/me: returns the signed-in user's profile, scoped permissions,
 * and the brands and locations they can access.
 *
 * Used by the frontend after login to build navigation and location pickers.
 * Dependencies are passed in so the router can be tested without real
 * Supabase or database connections.
 */
export function createMeRouter(
  deps: { pool: Pool; requireAuth: RequestHandler }
) {
  const router = Router()
  const getMe = createGetMeController(deps.pool)
  // requireAuth verifies the access token and sets res.locals.actorId.
  router.get('/', deps.requireAuth, getMe)
  return router;
}