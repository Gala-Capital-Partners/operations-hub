import { Pool } from 'pg';
import { type RequestHandler } from 'express';
import { MeRows } from '../types/me.js';
import { withUserTransaction } from '../db/transaction.js';

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

// Keep the public camelCase response independent of database column names.
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
 * Creates the GET /api/me handler using the injected database pool.
 * Mount after requireAuth: res.locals.actorId must be a verified user ID.
 * Database errors propagate to Express 5's application error handler.
 */
export function createGetMeController(pool: Pool): RequestHandler {
  return async (_req, res) => {
    // All queries use the same connection and transaction-local actor context.
    const result = await withUserTransaction(
      pool,
      res.locals.actorId,
      async (db) => {
        const profile = await db.query(PROFILE_SQL)
        // Auth membership alone does not grant an active application profile.
        if (profile.rowCount === 0) return null
        // Database helpers and RLS determine the visible permissions and resources.
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
    res.json(toMeResponse(result))
  }
}
