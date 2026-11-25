import type { MeResponse } from '@/lib/api/me'
import type { Role } from '@/lib/types'

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

/**
 * Brand to show after sign-in: the preferred one if the user can access it,
 * otherwise the first brand they can see.
 */
export function brandFromAccess(me: MeResponse, preferred?: string): string | null {
  const brands = me.brands.map(b => b.slug)
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

/**
 * The account's stores in one brand, in the order the Tasks screen lists them
 * (store number, then name). The first one is the user's default store.
 */
export function brandLocations<L extends { brandId: string; name: string; storeNumber: string | null }>(
  account: { brands: { id: string; slug: string }[]; locations: L[] },
  brandSlug: string,
): L[] {
  const brandId = account.brands.find(b => b.slug === brandSlug)?.id
  return account.locations
    .filter(l => l.brandId === brandId)
    .sort((a, b) => (a.storeNumber ?? a.name).localeCompare(b.storeNumber ?? b.name))
}
