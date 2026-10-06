'use client'

import { useRouter } from 'next/navigation'
import { useEffect } from 'react'
import { LoginScreen } from '@/components/screens/login-screen'
import { useSession } from '@/components/session-provider'

// "/" — sign-in screen. Already signed in? Go straight to the dashboard.
export default function LoginPage() {
  const router = useRouter()
  const { session, ready, login } = useSession()

  useEffect(() => {
    if (ready && session) router.replace('/dashboard')
  }, [ready, session, router])

  if (!ready || session) return null

  return (
    <LoginScreen
      onLogin={(role, brand) => {
        login(role, brand)
        router.push('/dashboard')
      }}
    />
  )
}
