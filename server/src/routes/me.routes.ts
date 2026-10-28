import { Router, type RequestHandler } from 'express';
import { withUserTransaction } from '../db/transaction.js';
import { Pool } from 'pg';
import { MeRows } from '../types/me.js';

const PROFILE_SQL = `
  SELECT id, email, full_name, organization_id
  FROM public.users
  WHERE id = identity_access.current_active_user_id();
`

const PERMISSIONS_SQL = `
  SELECT permission_key, role_key, role_scope, organization_id,
    brand_id, location_id
  FROM identity_access.current_user_permissions()
  ORDER BY permission_key;
`

const BRANDS_SQL = "SELECT id, name, slug FROM public.brands ORDER BY name;"

const LOCATIONS_SQL = `
  SELECT id, brand_id, name, store_number, timezone
  FROM public.locations
  ORDER BY name;
`

function toMeResponse(rows: MeRows) {
  return {
    user: {
      id: rows.profile.id,
      email: rows.profile.email,
      fullName: rows.profile.full_name,
      organizationId: rows.profile.organization_id,
    },
    permissions: rows.permissions.map(p => ({
      permission: p.permission_key,
      role: p.role_key,
      scope: p.role_scope,
      organizationId: p.organization_id,
      brandId: p.brand_id,
      locationId: p.location_id,
    })),
    brands: rows.brands.map(b => ({ id: b.id, name: b.name, slug: b.slug })),
    locations: rows.locations.map(l => ({
      id: l.id,
      brandId: l.brand_id,
      name: l.name,
      storeNumber: l.store_number,
      timezone: l.timezone,
    })),
  }
}

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
  // requireAuth verifies the access token and sets res.locals.actorId.
  router.get('/', deps.requireAuth, async (_req, res) => {
    const result = await withUserTransaction(
      deps.pool,
      res.locals.actorId,
      async (db) => {
        const profile = await db.query(PROFILE_SQL)
        if (profile.rowCount === 0) return null
        const [permissions, brands, locations] = [
          await db.query(PERMISSIONS_SQL),
          await db.query(BRANDS_SQL),
          await db.query(LOCATIONS_SQL),
        ]
        return {
          profile: profile.rows[0],
          permissions: permissions.rows,
          brands: brands.rows,
          locations: locations.rows
        }
      }
    )

    if (!result) {
      res.status(403).json({ error:
        {
          code: 'PROFILE_NOT_FOUND',
          message: 'No active application profile'
        }
      })
      return
    }
    res.json(toMeResponse(result))   // map snake_case → camelCase
  })
  return router;
}