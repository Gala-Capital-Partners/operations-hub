'use client'

import { useRouter } from 'next/navigation'
import { useEffect } from 'react'
import { LoginScreen } from '@/components/screens/login-screen'
import { useSession } from '@/components/session-provider'

// "/" — sign-in screen. Already signed in? Go straight to the dashboard.
export default function LoginPage() {
  const router = useRouter()
  const { session, ready, login, loginWithPassword, realAuth } = useSession()

  useEffect(() => {
    if (ready && session) router.replace('/dashboard')
  }, [ready, session, router])

  if (!ready || session) return null

  return (
    <LoginScreen
      realAuth={realAuth}
      onLogin={(role, brand) => {
        login(role, brand)
        router.push('/dashboard')
      }}
      onPasswordLogin={async (email, password, brand) => {
        await loginWithPassword(email, password, brand)
        router.push('/dashboard')
      }}
    />
  )
}
