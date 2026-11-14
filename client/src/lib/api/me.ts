import { API_BASE_URL, ApiError } from '@/lib/api/tasks'

/** Response of GET /api/me (server/src/controller/me.controller.ts). */
export type MeResponse = {
  user: { id: string; email: string; fullName: string; organizationId: string }
  permissions: {
    permission: string
    role: 'org_admin' | 'brand_admin' | 'location_manager' | 'employee'
    scope: 'organization' | 'brand' | 'location'
    organizationId: string
    brandId: string | null
    locationId: string | null
  }[]
  brands: { id: string; name: string; slug: string }[]
  locations: { id: string; brandId: string; name: string; storeNumber: string | null; timezone: string }[]
}

/** Load the signed-in user's profile and scoped access from the backend. */
export async function fetchMe(accessToken: string): Promise<MeResponse> {
  let res: Response
  try {
    res = await fetch(`${API_BASE_URL}/me`, {
      headers: { Authorization: `Bearer ${accessToken}` },
      cache: 'no-store',
    })
  } catch {
    throw new ApiError(`Cannot reach the API at ${API_BASE_URL}. Is the backend running?`, 0)
  }

  const body = await res.json().catch(() => null)
  if (!res.ok) {
    const message =
      body?.error?.code === 'PROFILE_NOT_FOUND'
        ? 'This account has no active OpsHub profile. Ask your administrator for access.'
        : (body?.error?.message ?? `Request failed (${res.status})`)
    throw new ApiError(message, res.status)
  }
  return body as MeResponse
}
