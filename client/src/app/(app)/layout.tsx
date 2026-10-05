'use client'

import { usePathname, useRouter } from 'next/navigation'
import { useEffect, type ReactNode } from 'react'
import { useSession } from '@/components/session-provider'
import { Shell } from '@/components/shell'
import { getNavItems } from '@/lib/config'
import type { Screen } from '@/lib/types'

// Layout shared by every signed-in screen: sidebar / mobile tab bar + role guard.
export default function AppLayout({ children }: { children: ReactNode }) {
  const router = useRouter()
  const pathname = usePathname()
  const { session, ready, logout, setRole, setBrand } = useSession()

  const screen = (pathname.split('/')[1] || 'dashboard') as Screen
  const allowed = session ? getNavItems(session.role).some(item => item.id === screen) : false

  useEffect(() => {
    if (!ready) return
    if (!session) router.replace('/')
    // e.g. Compliance is only for Corporate / Brand admins
    else if (!allowed) router.replace('/dashboard')
  }, [ready, session, allowed, router])

  if (!ready || !session || !allowed) return null

  return (
    <Shell
      role={session.role}
      brand={session.brand}
      screen={screen}
      onBrandSwitch={setBrand}
      onRoleSwitch={setRole}
      onLogout={() => {
        logout()
        router.replace('/')
      }}
    >
      {children}
    </Shell>
  )
}
