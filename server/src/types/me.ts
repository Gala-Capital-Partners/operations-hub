export type MeRows = {
  profile: { id: string; email: string; full_name: string; organization_id: string }
  permissions: Array<{
    permission_key: string; role_key: string; role_scope: string
    organization_id: string; brand_id: string | null; location_id: string | null
  }>
  brands: Array<{ id: string; name: string; slug: string }>
  locations: Array<{ id: string; brand_id: string; name: string; store_number: string | null; timezone: string }>
}
