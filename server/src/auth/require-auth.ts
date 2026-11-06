import type { RequestHandler } from 'express'
import type { SupabaseClient } from '@supabase/supabase-js'
import { extractBearerToken } from './bearer-token.js'

/**
 * Verifies the incoming access token and stores the authenticated
 * user's ID for later handlers in this request.
 */
export function createRequireAuth(
  authClient: SupabaseClient,
): RequestHandler {
  return async (req, res, next) => {
    const token = extractBearerToken(req.get('authorization'))

    if (!token) {
      res.status(401).json({
        error: { message: 'Authentication required' },
      })
      return
    }

    const { data, error } = await authClient.auth.getUser(token)

    if (error) {
      // Invalid credentials and authentication-service failures
      // should produce different responses.
      const invalidCredentials =
        error.status === 401 || error.status === 403

      res.status(invalidCredentials ? 401 : 503).json({
        error: {
          message: invalidCredentials
            ? 'Invalid or expired access token'
            : 'Authentication service unavailable',
        },
      })
      return
    }

    if (!data.user) {
      res.status(401).json({
        error: { message: 'Authentication required' },
      })
      return
    }

    // This ID comes from verified authentication, not request input.
    res.locals.actorId = data.user.id

    next()
  }
}