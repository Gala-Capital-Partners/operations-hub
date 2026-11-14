import { createClient, type SupabaseClient } from '@supabase/supabase-js'

// Browser-safe settings: the publishable key is meant to be public.
// Never put the database URL or a secret/service-role key in NEXT_PUBLIC_* variables.
const url = process.env.NEXT_PUBLIC_SUPABASE_URL?.trim() ?? ''
const publishableKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY?.trim() ?? ''

/**
 * True when both Supabase settings are present. Without them the app keeps the
 * demo sign-in (role/brand picker) so it still runs with no database at all.
 */
export const isSupabaseConfigured = url !== '' && publishableKey !== ''

let client: SupabaseClient | null = null

/** The shared Supabase client, or null when Supabase isn't configured. */
export function getSupabase(): SupabaseClient | null {
  if (!isSupabaseConfigured) return null
  client ??= createClient(url, publishableKey, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false },
  })
  return client
}

/** The signed-in user's current access token (refreshed by supabase-js), or null. */
export async function getAccessToken(): Promise<string | null> {
  const supabase = getSupabase()
  if (!supabase) return null
  const { data } = await supabase.auth.getSession()
  return data.session?.access_token ?? null
}
