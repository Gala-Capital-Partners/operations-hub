'use client'

import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import type { Brand, Role } from '@/lib/types'

/**
 * Demo "session": which role and brand the user signed in with.
 * There is no real authentication yet — this mirrors the original Figma prototype,
 * and is persisted to localStorage so a page refresh keeps you signed in.
 */
type Session = { role: Role; brand: Brand }

type SessionContextValue = {
  session: Session | null
  /** false until localStorage has been read on the client */
  ready: boolean
  login: (role: Role, brand: Brand) => void
  logout: () => void
  setRole: (role: Role) => void
  setBrand: (brand: Brand) => void
}

const STORAGE_KEY = 'opshub.session'
const SessionContext = createContext<SessionContextValue | null>(null)

function readStored(): Session | null {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    return raw ? (JSON.parse(raw) as Session) : null
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

  useEffect(() => {
    // Read persisted session once on the client (localStorage isn't available during SSR)
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setSession(readStored())
    setReady(true)
  }, [])

  const update = useCallback((next: Session | null) => {
    setSession(next)
    writeStored(next)
  }, [])

  const value = useMemo<SessionContextValue>(
    () => ({
      session,
      ready,
      login: (role, brand) => update({ role, brand }),
      logout: () => update(null),
      setRole: role => session && update({ ...session, role }),
      setBrand: brand => session && update({ ...session, brand }),
    }),
    [session, ready, update],
  )

  return <SessionContext.Provider value={value}>{children}</SessionContext.Provider>
}

export function useSession() {
  const ctx = useContext(SessionContext)
  if (!ctx) throw new Error('useSession must be used inside <SessionProvider>')
  return ctx
}
