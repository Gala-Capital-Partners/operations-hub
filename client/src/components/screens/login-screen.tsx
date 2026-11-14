'use client'

import { useState, type FormEvent } from 'react'
import { BRANDS, ROLES } from '@/lib/config'
import { type Brand, type Role } from '@/lib/types'

export function LoginScreen({
  onLogin,
  realAuth = false,
  onPasswordLogin,
}: {
  /** Demo sign-in: pick any role and brand. */
  onLogin: (role: Role, brand: Brand) => void
  /** True when Supabase is configured: show email + password sign-in instead of the role picker. */
  realAuth?: boolean
  /** Real sign-in; rejects with an Error whose message is shown to the user. */
  onPasswordLogin?: (email: string, password: string, brand: Brand) => Promise<void>
}) {
  const [brand, setBrand] = useState<Brand>('burgercraft')
  const [role, setRole] = useState<Role>('manager')
  const [email, setEmail] = useState(realAuth ? '' : 'jordan.lee@burgercraft.com')
  const [password, setPassword] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const b = BRANDS[brand]

  const submitPassword = async (e: FormEvent) => {
    e.preventDefault()
    if (!onPasswordLogin || submitting) return
    if (!email.trim() || !password) {
      setError('Enter your email and password.')
      return
    }
    setSubmitting(true)
    setError(null)
    try {
      await onPasswordLogin(email, password, brand)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Sign-in failed. Please try again.')
      setSubmitting(false)
    }
  }

  return (
    <div className="min-h-screen flex flex-col md:flex-row">
      {/* Brand panel */}
      <div
        className="flex flex-col items-center justify-center py-14 px-10 md:w-[46%] md:min-h-screen relative overflow-hidden"
        style={{ backgroundColor: b.accent }}
      >
        <div
          className="absolute inset-0 opacity-[0.08]"
          style={{ backgroundImage: 'radial-gradient(circle, white 1.5px, transparent 1.5px)', backgroundSize: '28px 28px' }}
        />
        <div className="relative z-10 text-center">
          <div className="w-20 h-20 rounded-2xl bg-white/20 flex items-center justify-center mx-auto mb-5 text-4xl">
            {brand === 'burgercraft' ? '🍔' : '🌮'}
          </div>
          <p className="text-white/60 text-xs font-semibold uppercase tracking-widest mb-2">OpsHub</p>
          <h1 className="text-white text-3xl font-bold tracking-tight">{b.name}</h1>
          <p className="text-white/60 text-sm mt-1.5">{b.locations} locations · Operations Platform</p>
        </div>
        {/* Brand toggle */}
        <div className="relative z-10 mt-8 bg-white/20 rounded-full flex p-1">
          {(['burgercraft', 'tacoverde'] as Brand[]).map(br => (
            <button
              key={br}
              onClick={() => setBrand(br)}
              className={`px-5 py-1.5 rounded-full text-sm font-semibold transition-all ${brand === br ? 'bg-white text-stone-900 shadow' : 'text-white/80 hover:text-white'}`}
            >
              {BRANDS[br].short}
            </button>
          ))}
        </div>
        <p className="relative z-10 text-white/40 text-xs mt-6">One login. Both brands.</p>
      </div>

      {/* Form panel */}
      <div className="flex-1 flex items-center justify-center p-8 bg-white">
        <div className="w-full max-w-sm">
          <div className="mb-8">
            <p className="text-xs font-semibold text-stone-400 uppercase tracking-widest mb-3">Sign in</p>
            <h2 className="text-2xl font-semibold text-stone-900">Welcome back</h2>
            <p className="text-stone-500 text-sm mt-1">Signing into <strong>{b.name}</strong> OpsHub.</p>
          </div>

          {realAuth ? (
            <form className="space-y-4" onSubmit={submitPassword} noValidate>
              <div>
                <label htmlFor="login-email" className="block text-xs font-semibold text-stone-500 uppercase tracking-wide mb-1.5">Email address</label>
                <input
                  id="login-email"
                  type="email"
                  autoComplete="username"
                  value={email}
                  onChange={e => setEmail(e.target.value)}
                  placeholder="you@company.com"
                  className="w-full border border-stone-200 rounded-xl px-4 py-2.5 text-sm text-stone-900 placeholder:text-stone-400 focus:outline-none focus:border-teal-600 focus:ring-2 focus:ring-teal-600/20 transition-all bg-white"
                />
              </div>
              <div>
                <label htmlFor="login-password" className="block text-xs font-semibold text-stone-500 uppercase tracking-wide mb-1.5">Password</label>
                <input
                  id="login-password"
                  type="password"
                  autoComplete="current-password"
                  value={password}
                  onChange={e => setPassword(e.target.value)}
                  className="w-full border border-stone-200 rounded-xl px-4 py-2.5 text-sm text-stone-900 focus:outline-none focus:border-teal-600 focus:ring-2 focus:ring-teal-600/20 transition-all bg-white"
                />
              </div>

              {error && (
                <p role="alert" className="text-sm text-red-700 bg-red-50 border border-red-200 rounded-xl px-3 py-2">{error}</p>
              )}

              <button
                type="submit"
                disabled={submitting}
                className="w-full py-2.5 rounded-xl text-sm font-semibold text-white transition-all hover:opacity-90 active:scale-[0.98] disabled:opacity-60 disabled:cursor-wait"
                style={{ backgroundColor: b.accent }}
              >
                {submitting ? 'Signing in…' : 'Sign in to OpsHub'}
              </button>
            </form>
          ) : (
          <div className="space-y-4">
            <div>
              <label className="block text-xs font-semibold text-stone-500 uppercase tracking-wide mb-1.5">Email address</label>
              <input
                type="email"
                value={email}
                onChange={e => setEmail(e.target.value)}
                className="w-full border border-stone-200 rounded-xl px-4 py-2.5 text-sm text-stone-900 placeholder:text-stone-400 focus:outline-none focus:border-teal-600 focus:ring-2 focus:ring-teal-600/20 transition-all bg-white"
              />
            </div>
            <div>
              <div className="flex justify-between items-center mb-1.5">
                <label className="text-xs font-semibold text-stone-500 uppercase tracking-wide">Password</label>
                <button className="text-xs text-teal-700 hover:underline">Forgot?</button>
              </div>
              <input
                type="password"
                defaultValue="••••••••"
                className="w-full border border-stone-200 rounded-xl px-4 py-2.5 text-sm text-stone-900 focus:outline-none focus:border-teal-600 focus:ring-2 focus:ring-teal-600/20 transition-all bg-white"
              />
            </div>

            <div>
              <label className="block text-xs font-semibold text-stone-500 uppercase tracking-wide mb-1.5">Preview role</label>
              <select
                value={role}
                onChange={e => setRole(e.target.value as Role)}
                className="w-full border border-stone-200 rounded-xl px-4 py-2.5 text-sm text-stone-900 focus:outline-none focus:border-teal-600 focus:ring-2 focus:ring-teal-600/20 transition-all bg-white"
              >
                {(Object.entries(ROLES) as [Role, typeof ROLES[Role]][]).map(([k, v]) => (
                  <option key={k} value={k}>{v.label}</option>
                ))}
              </select>
            </div>

            <button
              onClick={() => onLogin(role, brand)}
              className="w-full py-2.5 rounded-xl text-sm font-semibold text-white transition-all hover:opacity-90 active:scale-[0.98]"
              style={{ backgroundColor: b.accent }}
            >
              Sign in to OpsHub
            </button>
          </div>
          )}

          <p className="text-xs text-stone-400 text-center mt-6">
            Access issues? Contact your administrator.
          </p>
        </div>
      </div>
    </div>
  )
}
