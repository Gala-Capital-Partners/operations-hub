import { createClient } from '@supabase/supabase-js'

/**
 * Extracts a Bearer token from an Authorization header.
 * This only reads the token; it does not verify its authenticity.
 */
export function extractBearerToken(
  authorization: string | undefined,
): string | null {
  if (!authorization) {
    return null
  }

  const match = /^Bearer[ \t]+(\S+)$/i.exec(authorization.trim())

  return match?.[1] ?? null
}

/**
 * Creates a client for verifying incoming access tokens.
 * The backend does not maintain its own user session.
 */
export function createAuthClient() {
  const url = process.env.SUPABASE_URL
  const key = process.env.SUPABASE_PUBLISHABLE_KEY

  if (!url || !key) {
    throw new Error('Missing Supabase authentication configuration')
  }

  return createClient(url, key, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
  })
}