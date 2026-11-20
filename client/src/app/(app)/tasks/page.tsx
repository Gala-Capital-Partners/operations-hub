'use client'

import { TasksDbScreen } from '@/components/screens/tasks-db-screen'
import { TasksScreen } from '@/components/screens/tasks-screen'
import { useSession } from '@/components/session-provider'

export default function Page() {
  const { session } = useSession()
  if (!session) return null
  // Signed-in users work with real database task instances; the demo keeps the prototype API.
  if (session.mode === 'supabase') return <TasksDbScreen account={session.account} brand={session.brand} />
  return <TasksScreen role={session.role} />
}
