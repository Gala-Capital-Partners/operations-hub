'use client'

import { TasksScreen } from '@/components/screens/tasks-screen'
import { useSession } from '@/components/session-provider'

export default function Page() {
  const { session } = useSession()
  if (!session) return null
  return <TasksScreen role={session.role} />
}
