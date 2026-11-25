'use client'

import { DashboardScreen } from '@/components/screens/dashboard-screen'
import { BRANDS } from '@/lib/config'
import { useSession } from '@/components/session-provider'
import { brandLocations } from '@/lib/auth'

export default function Page() {
  const { session } = useSession()
  if (!session) return null
  // Employees and managers see their default store's checklist (the Tasks page's first
  // store); organization and brand admins get the location rollup instead.
  const homeLocation =
    session.mode === 'supabase' && (session.role === 'employee' || session.role === 'manager')
      ? (brandLocations(session.account, session.brand)[0] ?? null)
      : null
  return (
    <DashboardScreen
      role={session.role}
      brandName={session.mode === 'demo' ? BRANDS[session.brand].name : session.account.brands.find(b => b.slug === session.brand)?.name ?? session.brand}
      userName={session.mode === 'supabase' ? session.account.fullName : undefined}
      live={session.mode === 'supabase'}
      homeLocation={homeLocation}
    />
  )
}
