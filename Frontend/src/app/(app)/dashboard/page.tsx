'use client'

import { DashboardScreen } from '@/components/screens/dashboard-screen'
import { useSession } from '@/components/session-provider'

export default function Page() {
  const { session } = useSession()
  if (!session) return null
  return <DashboardScreen role={session.role} brand={session.brand} />
}
