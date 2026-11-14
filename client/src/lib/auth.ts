import type { MeResponse } from '@/lib/api/me'
import { BRANDS } from '@/lib/config'
import type { Brand, Role } from '@/lib/types'

// Database role keys -> the app's UI roles, highest authority first.
const ROLE_PRIORITY: [MeResponse['permissions'][number]['role'], Role][] = [
  ['org_admin', 'corporate'],
  ['brand_admin', 'brand'],
  ['location_manager', 'manager'],
  ['employee', 'employee'],
]

/** The UI role for a user: their highest-authority assigned role, or null if they have none. */
export function roleFromAccess(me: MeResponse): Role | null {
  const held = new Set(me.permissions.map(p => p.role))
  return ROLE_PRIORITY.find(([dbRole]) => held.has(dbRole))?.[1] ?? null
}

function isBrand(slug: string): slug is Brand {
  return slug in BRANDS
}

/** Brands the user can see that the UI knows how to theme. */
export function accessibleBrands(me: MeResponse): Brand[] {
  return me.brands.map(b => b.slug).filter(isBrand)
}

/**
 * Brand to show after sign-in: the preferred one if the user can access it,
 * otherwise the first brand they can see.
 */
export function brandFromAccess(me: MeResponse, preferred?: Brand): Brand | null {
  const brands = accessibleBrands(me)
  if (preferred && brands.includes(preferred)) return preferred
  return brands[0] ?? null
}

export function initialsOf(fullName: string): string {
  const parts = fullName.trim().split(/\s+/).filter(Boolean)
  return ((parts[0]?.[0] ?? '') + (parts.length > 1 ? parts[parts.length - 1][0] : '')).toUpperCase() || '?'
}

/**
 * Whether the account holds a permission at a location (organization-, brand- or
 * location-scoped). Only for showing or hiding controls: the API enforces access.
 */
export function canAtLocation(
  account: { permissions?: { permission: string; scope: string; brandId: string | null; locationId: string | null }[]; locations: { id: string; brandId: string }[] },
  permission: string,
  locationId: string,
): boolean {
  const location = account.locations.find(l => l.id === locationId)
  if (!location) return false
  return (account.permissions ?? []).some(
    p =>
      p.permission === permission &&
      (p.scope === 'organization' ||
        (p.scope === 'brand' && p.brandId === location.brandId) ||
        (p.scope === 'location' && p.locationId === locationId)),
  )
}
