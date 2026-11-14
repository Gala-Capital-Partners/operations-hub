'use client'

import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { fetchMe, type MeResponse } from '@/lib/api/me'
import { brandFromAccess, initialsOf, roleFromAccess } from '@/lib/auth'
import { getSupabase, isSupabaseConfigured } from '@/lib/supabase'
import type { Brand, Role } from '@/lib/types'

/**
 * Two kinds of session:
 *  - "demo": the original prototype's role/brand picker, with no authentication.
 *    Used when Supabase isn't configured (see lib/supabase.ts).
 *  - "supabase": a real Supabase Auth sign-in. Role, brand and name come from
 *    GET /api/me, i.e. from the database's role assignments, and can't be switched.
 * Persisted to localStorage so a refresh keeps you signed in (supabase-js stores
 * its own auth tokens separately).
 */
export type Account = {
  userId: string
  email: string
  fullName: string
  initials: string
  brands: MeResponse['brands']
  locations: MeResponse['locations']
}

export type Session =
  | { mode: 'demo'; role: Role; brand: Brand }
  | { mode: 'supabase'; role: Role; brand: Brand; account: Account }

type SessionContextValue = {
  session: Session | null
  /** false until the stored session has been read (and, for Supabase, checked) on the client */
  ready: boolean
  /** Whether sign-in uses Supabase (email + password) or the demo picker */
  realAuth: boolean
  login: (role: Role, brand: Brand) => void
  /** Real sign-in. Throws an Error with a user-facing message on failure. */
  loginWithPassword: (email: string, password: string, preferredBrand?: Brand) => Promise<void>
  logout: () => void
  setRole: (role: Role) => void
  setBrand: (brand: Brand) => void
}

const STORAGE_KEY = 'opshub.session'
const SessionContext = createContext<SessionContextValue | null>(null)

function readStored(): Session | null {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return null
    const parsed = JSON.parse(raw) as Partial<Session>
    // Sessions saved before real sign-in existed have no mode: treat them as demo.
    return (parsed.mode ? parsed : { ...parsed, mode: 'demo' }) as Session
  } catch {
    return null
  }
}

function writeStored(s: Session | null) {
  try {
    if (s) localStorage.setItem(STORAGE_KEY, JSON.stringify(s))
    else localStorage.removeItem(STORAGE_KEY)
  } catch {
    /* storage unavailable — session just won't survive a refresh */
  }
}

export function SessionProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [ready, setReady] = useState(false)

  const update = useCallback((next: Session | null) => {
    setSession(next)
    writeStored(next)
  }, [])

  useEffect(() => {
    // Read persisted session once on the client (localStorage isn't available during SSR)
    const stored = readStored()
    const supabase = getSupabase()

    // A session must match how sign-in is configured right now.
    const usable = stored && (stored.mode === 'supabase') === isSupabaseConfigured ? stored : null

    if (!usable || usable.mode === 'demo' || !supabase) {
      if (stored && !usable) writeStored(null)
      // eslint-disable-next-line react-hooks/set-state-in-effect
      setSession(usable)
      setReady(true)
      return
    }

    // Real session: only keep it if Supabase still has a signed-in user.
    let cancelled = false
    supabase.auth.getSession().then(({ data }) => {
      if (cancelled) return
      const valid = data.session?.user.id === usable.account.userId
      if (!valid) writeStored(null)
      setSession(valid ? usable : null)
      setReady(true)
    })
    return () => { cancelled = true }
  }, [])

  // Signed out elsewhere (another tab, expired refresh token): drop the app session too.
  useEffect(() => {
    const supabase = getSupabase()
    if (!supabase) return
    const { data } = supabase.auth.onAuthStateChange(event => {
      if (event === 'SIGNED_OUT') update(null)
    })
    return () => data.subscription.unsubscribe()
  }, [update])

  const loginWithPassword = useCallback(
    async (email: string, password: string, preferredBrand?: Brand) => {
      const supabase = getSupabase()
      if (!supabase) throw new Error('Sign-in is not configured.')

      const { data, error } = await supabase.auth.signInWithPassword({ email: email.trim(), password })
      if (error || !data.session) {
        throw new Error(
          error?.status === 400 || error?.code === 'invalid_credentials'
            ? 'Incorrect email or password.'
            : 'Sign-in failed. Please try again.',
        )
      }

      try {
        const me = await fetchMe(data.session.access_token)
        const role = roleFromAccess(me)
        const brand = brandFromAccess(me, preferredBrand)
        if (!role || !brand) {
          throw new Error('Your account has no role assignment yet. Ask your administrator for access.')
        }
        update({
          mode: 'supabase',
          role,
          brand,
          account: {
            userId: me.user.id,
            email: me.user.email,
            fullName: me.user.fullName,
            initials: initialsOf(me.user.fullName),
            brands: me.brands,
            locations: me.locations,
          },
        })
      } catch (err) {
        // Don't leave a Supabase login behind without an app session.
        await supabase.auth.signOut().catch(() => undefined)
        throw err instanceof Error ? err : new Error('Sign-in failed. Please try again.')
      }
    },
    [update],
  )

  const value = useMemo<SessionContextValue>(
    () => ({
      session,
      ready,
      realAuth: isSupabaseConfigured,
      login: (role, brand) => update({ mode: 'demo', role, brand }),
      loginWithPassword,
      logout: () => {
        if (session?.mode === 'supabase') getSupabase()?.auth.signOut().catch(() => undefined)
        update(null)
      },
      // Real users' roles come from the database; only the demo can switch roles.
      setRole: role => session?.mode === 'demo' && update({ ...session, role }),
      setBrand: brand => {
        if (!session) return
        if (session.mode === 'supabase' && !session.account.brands.some(b => b.slug === brand)) return
        update({ ...session, brand })
      },
    }),
    [session, ready, update, loginWithPassword],
  )

  return <SessionContext.Provider value={value}>{children}</SessionContext.Provider>
}

export function useSession() {
  const ctx = useContext(SessionContext)
  if (!ctx) throw new Error('useSession must be used inside <SessionProvider>')
  return ctx
}
