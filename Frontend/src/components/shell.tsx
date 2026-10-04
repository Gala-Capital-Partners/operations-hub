'use client'

import Link from 'next/link'
import { useEffect, useState, type ReactNode } from 'react'
import { Ic } from '@/components/icons'
import { BRANDS, ROLES, getNavItems } from '@/lib/config'
import { type Brand, type Role, type Screen } from '@/lib/types'

export function Shell({
  children, role, brand, screen, onBrandSwitch, onRoleSwitch, onLogout,
}: {
  children: ReactNode
  role: Role
  brand: Brand
  screen: Screen
  onBrandSwitch: (b: Brand) => void
  onRoleSwitch: (r: Role) => void
  onLogout: () => void
}) {
  const navItems = getNavItems(role)
  // Mobile account menu (role switch + sign out), opened from the avatar in the mobile header
  const [menuOpen, setMenuOpen] = useState(false)

  useEffect(() => {
    if (!menuOpen) return
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && setMenuOpen(false)
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [menuOpen])
  const b = BRANDS[brand]
  const r = ROLES[role]

  const NavIcon = (id: string) => ({
    dashboard: <Ic.Dashboard />,
    knowledge: <Ic.Knowledge />,
    tasks: <Ic.Tasks />,
    training: <Ic.Training />,
    compliance: <Ic.Compliance />,
  }[id] ?? null)

  return (
    <div className="min-h-screen bg-stone-50 flex">
      {/* Desktop sidebar */}
      <aside className="hidden md:flex flex-col w-60 bg-white border-r border-stone-200 fixed top-0 left-0 bottom-0 z-30">
        {/* Brand header */}
        <div className="p-4 border-b border-stone-100">
          <div className="flex items-center gap-2.5 mb-3">
            <div
              className="w-8 h-8 rounded-lg flex items-center justify-center text-white text-xs font-bold flex-shrink-0"
              style={{ backgroundColor: b.accent }}
            >
              {b.short}
            </div>
            <div className="min-w-0">
              <p className="text-sm font-semibold text-stone-900 truncate">{b.name}</p>
              <p className="text-[10px] text-stone-400">OpsHub · {b.locations} locations</p>
            </div>
          </div>
          {/* Brand switcher — Corporate Admin only */}
          {role === 'corporate' && (
            <div className="bg-stone-100 rounded-lg p-1 flex gap-1">
              {(['burgercraft', 'tacoverde'] as Brand[]).map(br => (
                <button
                  key={br}
                  onClick={() => onBrandSwitch(br)}
                  className={`flex-1 py-1 rounded text-[11px] font-bold transition-all ${brand === br ? 'bg-white text-stone-900 shadow-sm' : 'text-stone-400 hover:text-stone-600'}`}
                >
                  {BRANDS[br].short}
                </button>
              ))}
            </div>
          )}
        </div>

        {/* Nav */}
        <nav className="flex-1 py-3 px-2 overflow-y-auto">
          {navItems.map(item => {
            const active = screen === item.id
            return (
              <Link
                key={item.id}
                href={`/${item.id}`}
                aria-current={active ? 'page' : undefined}
                className={`w-full flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium mb-0.5 transition-all ${active ? 'bg-teal-50 text-teal-800 border-l-2 border-teal-700' : 'text-stone-500 hover:bg-stone-50 hover:text-stone-900 border-l-2 border-transparent'}`}
              >
                <span className={`flex-shrink-0 ${active ? 'text-teal-700' : 'text-stone-400'}`}>
                  {NavIcon(item.id)}
                </span>
                {item.label}
              </Link>
            )
          })}
        </nav>

        {/* Bottom */}
        <div className="border-t border-stone-100 p-4 space-y-3">
          <div>
            <p className="text-[10px] font-semibold text-stone-400 uppercase tracking-widest mb-1.5">Demo: Switch Role</p>
            <select
              value={role}
              onChange={e => onRoleSwitch(e.target.value as Role)}
              className="w-full text-xs border border-stone-200 rounded-lg px-2.5 py-1.5 text-stone-700 bg-white focus:outline-none focus:border-teal-600"
            >
              {(Object.entries(ROLES) as [Role, typeof ROLES[Role]][]).map(([k, v]) => (
                <option key={k} value={k}>{v.label}</option>
              ))}
            </select>
          </div>
          <div className="flex items-center gap-2.5">
            <div className="w-7 h-7 rounded-full bg-teal-100 flex items-center justify-center text-xs font-bold text-teal-800 flex-shrink-0">
              {r.initials}
            </div>
            <div className="flex-1 min-w-0">
              <p className="text-xs font-semibold text-stone-900 truncate">{r.name}</p>
              <p className="text-[10px] text-stone-400 truncate">{r.label}</p>
            </div>
            <button onClick={onLogout} className="text-[10px] text-stone-400 hover:text-red-500 transition-colors font-medium">
              Sign out
            </button>
          </div>
        </div>
      </aside>

      {/* Main column — page content is rendered ONCE (the Figma export mounted it twice,
          once for desktop and once for mobile, which would double every API call). */}
      <div className="flex flex-col flex-1 md:ml-60 min-h-screen min-w-0">
        {/* Desktop header */}
        <header className="hidden md:flex sticky top-0 bg-white/90 backdrop-blur border-b border-stone-200 px-6 py-3.5 items-center justify-between z-20">
          <div className="flex items-center gap-2">
            <span className="text-stone-300">{NavIcon(screen)}</span>
            <h2 className="text-sm font-semibold text-stone-900 capitalize">{screen}</h2>
          </div>
          <div className="flex items-center gap-1.5 text-xs text-stone-400">
            <Ic.Building />
            <span>{b.name} · {b.locations} locations</span>
          </div>
        </header>

        {/* Mobile header */}
        <header className="md:hidden sticky top-0 bg-white/90 backdrop-blur border-b border-stone-200 px-4 py-3 flex items-center justify-between z-20">
          <div className="flex items-center gap-2">
            <div
              className="w-6 h-6 rounded flex items-center justify-center text-white text-[10px] font-bold"
              style={{ backgroundColor: b.accent }}
            >
              {b.short}
            </div>
            <span className="text-sm font-semibold text-stone-900 capitalize">{screen}</span>
          </div>
          <div className="flex items-center gap-2">
            {role === 'corporate' && (
              <div className="bg-stone-100 rounded-md p-0.5 flex">
                {(['burgercraft', 'tacoverde'] as Brand[]).map(br => (
                  <button
                    key={br}
                    onClick={() => onBrandSwitch(br)}
                    className={`px-2 py-0.5 rounded text-[10px] font-bold transition-all ${brand === br ? 'bg-white text-stone-900 shadow-sm' : 'text-stone-400'}`}
                  >
                    {BRANDS[br].short}
                  </button>
                ))}
              </div>
            )}
            <div className="relative">
              <button
                onClick={() => setMenuOpen(o => !o)}
                className={`w-7 h-7 rounded-full bg-teal-100 flex items-center justify-center text-xs font-bold text-teal-800 transition-shadow ${menuOpen ? 'ring-2 ring-teal-600/40' : ''}`}
                aria-label="Account menu"
                aria-haspopup="menu"
                aria-expanded={menuOpen}
              >
                {r.initials}
              </button>

              {menuOpen && (
                <>
                  {/* click-away backdrop */}
                  <div className="fixed inset-0 z-30" onClick={() => setMenuOpen(false)} />
                  <div
                    role="menu"
                    className="absolute right-0 top-full mt-2 z-40 w-64 bg-white border border-stone-200 rounded-xl shadow-xl overflow-hidden"
                    style={{ animation: 'fadeScaleIn 0.15s ease-out', transformOrigin: 'top right' }}
                  >
                    <div className="flex items-center gap-2.5 px-4 py-3 border-b border-stone-100">
                      <div className="w-8 h-8 rounded-full bg-teal-100 flex items-center justify-center text-xs font-bold text-teal-800 flex-shrink-0">
                        {r.initials}
                      </div>
                      <div className="min-w-0">
                        <p className="text-sm font-semibold text-stone-900 truncate">{r.name}</p>
                        <p className="text-[11px] text-stone-400 truncate">{r.label} · {b.name}</p>
                      </div>
                    </div>
                    <div className="px-4 py-3 border-b border-stone-100">
                      <p className="text-[10px] font-semibold text-stone-400 uppercase tracking-widest mb-1.5">Demo: Switch Role</p>
                      <select
                        value={role}
                        onChange={e => { onRoleSwitch(e.target.value as Role); setMenuOpen(false) }}
                        className="w-full text-sm border border-stone-200 rounded-lg px-2.5 py-2 text-stone-700 bg-white focus:outline-none focus:border-teal-600"
                      >
                        {(Object.entries(ROLES) as [Role, typeof ROLES[Role]][]).map(([k, v]) => (
                          <option key={k} value={k}>{v.label}</option>
                        ))}
                      </select>
                    </div>
                    <button
                      role="menuitem"
                      onClick={() => { setMenuOpen(false); onLogout() }}
                      className="w-full text-left px-4 py-3 text-sm font-semibold text-red-600 hover:bg-red-50 active:bg-red-50 transition-colors"
                    >
                      Sign out
                    </button>
                  </div>
                </>
              )}
            </div>
          </div>
        </header>

        <main className="flex-1 overflow-auto pb-20 md:pb-0">{children}</main>

        {/* Mobile bottom tab bar */}
        <nav className="md:hidden fixed bottom-0 left-0 right-0 bg-white border-t border-stone-200 flex z-30">
          {navItems.map(item => {
            const active = screen === item.id
            return (
              <Link
                key={item.id}
                href={`/${item.id}`}
                onClick={() => setMenuOpen(false)}
                aria-current={active ? 'page' : undefined}
                className={`flex-1 flex flex-col items-center gap-0.5 py-2.5 transition-colors ${active ? 'text-teal-700' : 'text-stone-400'}`}
              >
                <span className="flex-shrink-0">{NavIcon(item.id)}</span>
                <span className="text-[10px] font-semibold">{item.label}</span>
              </Link>
            )
          })}
        </nav>
      </div>
    </div>
  )
}
