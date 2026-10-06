'use client'

import Link from 'next/link'
import { useTasks } from '@/hooks/use-tasks'
import { Ring, SalesChart } from '@/components/charts'
import { Ic } from '@/components/icons'
import { BRANDS, ROLES, TODAY } from '@/lib/config'
import { statusColor } from '@/lib/format'
import { LOCATION_DATA, SALES } from '@/lib/mock-data'
import { type Brand, type Role } from '@/lib/types'

export function DashboardScreen({ role, brand }: { role: Role; brand: Brand }) {
  const latest = SALES[SALES.length - 1]
  const diff = latest.today - latest.yesterday
  const pctStr = ((diff / latest.yesterday) * 100).toFixed(1)
  const positive = diff > 0
  // Tasks come from the backend API (was: useState(TASKS_DATA))
  const { tasks, toggleTask } = useTasks()
  const doneCount = tasks.filter(t => t.done).length

  function toggle(id: number) {
    void toggleTask(id)
  }

  const kpis = [
    { label: "Today's Sales", value: `$${(latest.today / 1000).toFixed(1)}k`, sub: `${positive ? '+' : ''}${pctStr}% vs yesterday`, trend: positive ? 'up' : 'down' as const },
    { label: 'Weekly Revenue', value: '$71.4k', sub: '+4.2% vs last week', trend: 'up' as const },
    { label: 'Avg Ticket', value: '$18.40', sub: '+$0.80 vs yesterday', trend: 'up' as const },
    { label: 'Tasks Today', value: `${doneCount}/${tasks.length}`, sub: 'At this location', trend: null },
  ]

  return (
    <div className="p-4 md:p-6 max-w-5xl mx-auto space-y-5">
      {/* Greeting */}
      <div>
        <h1 className="text-xl font-semibold text-stone-900">
          Good morning, {ROLES[role].name.split(' ')[0]}
        </h1>
        <p className="text-sm text-stone-500 mt-0.5">
          {new Date(TODAY + 'T00:00:00').toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric' })} · {BRANDS[brand].name}
        </p>
      </div>

      {/* KPI row */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
        {kpis.map(k => (
          <div key={k.label} className="bg-white rounded-xl border border-stone-200 p-4">
            <p className="text-[11px] font-semibold text-stone-400 uppercase tracking-wide">{k.label}</p>
            <p className="text-2xl font-semibold text-stone-900 mt-1.5 font-mono">{k.value}</p>
            <p className={`text-xs mt-1 flex items-center gap-1 font-medium ${k.trend === 'up' ? 'text-emerald-600' : k.trend === 'down' ? 'text-red-600' : 'text-stone-400'}`}>
              {k.trend === 'up' && <Ic.TrendUp />}
              {k.trend === 'down' && <Ic.TrendDown />}
              {k.sub}
            </p>
          </div>
        ))}
      </div>

      {/* Compliance alert — corporate/brand */}
      {(role === 'corporate' || role === 'brand') && (
        <div className="bg-amber-50 border border-amber-200 rounded-xl p-4 flex items-start gap-3">
          <span className="text-amber-500 mt-0.5 flex-shrink-0"><Ic.Alert /></span>
          <div>
            <p className="text-sm font-semibold text-amber-900">2 compliance documents expiring within 30 days</p>
            <p className="text-xs text-amber-700 mt-0.5">
              North Park Franchise Agreement expires in <strong>3 days</strong> · Downtown Flagship Agreement expires in 17 days
            </p>
          </div>
        </div>
      )}

      {/* Chart + tasks grid */}
      <div className="grid md:grid-cols-[1fr_300px] gap-4">
        {/* Sales chart */}
        <div className="bg-white rounded-xl border border-stone-200 p-5">
          <div className="flex items-start justify-between mb-4">
            <div>
              <h2 className="text-sm font-semibold text-stone-900">Sales — This Week</h2>
              <p className="text-xs text-stone-500 mt-0.5">Day-over-day comparison</p>
            </div>
            <div className="flex items-center gap-3">
              <span className="flex items-center gap-1.5 text-xs text-stone-500"><span className="w-2 h-2 rounded-sm bg-teal-700 inline-block" />Today</span>
              <span className="flex items-center gap-1.5 text-xs text-stone-500"><span className="w-2 h-2 rounded-sm bg-stone-200 inline-block" />Prev</span>
            </div>
          </div>
          <SalesChart />
          <div className="grid grid-cols-4 gap-2 mt-4 pt-4 border-t border-stone-100">
            {[
              { label: 'Week avg', value: '$10.1k' },
              { label: 'Best day', value: 'Sat' },
              { label: 'Peak hour', value: '12–1pm' },
              { label: 'Covers', value: '312' },
            ].map(s => (
              <div key={s.label}>
                <p className="text-[10px] text-stone-400 uppercase tracking-wide">{s.label}</p>
                <p className="text-sm font-semibold text-stone-900 font-mono mt-0.5">{s.value}</p>
              </div>
            ))}
          </div>
        </div>

        {/* My tasks */}
        <div className="bg-white rounded-xl border border-stone-200 p-5">
          <div className="flex items-start justify-between mb-4">
            <div>
              <h2 className="text-sm font-semibold text-stone-900">My Tasks Today</h2>
              <p className="text-xs text-stone-500 mt-0.5">{doneCount} of {tasks.length} complete</p>
            </div>
            <Ring pct={tasks.length ? Math.round((doneCount / tasks.length) * 100) : 0} size={44} />
          </div>
          <div className="space-y-1">
            {tasks.slice(0, 6).map(task => (
              <button
                key={task.id}
                onClick={() => toggle(task.id)}
                className="w-full flex items-start gap-2.5 py-1.5 text-left group"
              >
                <div className={`w-4 h-4 rounded-full flex-shrink-0 flex items-center justify-center border-2 transition-all mt-0.5 ${task.done ? 'bg-teal-700 border-teal-700' : 'border-stone-300 group-hover:border-teal-400'}`}>
                  {task.done && (
                    <svg viewBox="0 0 10 10" fill="none" stroke="white" strokeWidth={2.5} strokeLinecap="round" strokeLinejoin="round" className="w-2.5 h-2.5">
                      <polyline points="1.5 5 3.5 7.5 8.5 2.5" />
                    </svg>
                  )}
                </div>
                <span className={`text-sm leading-snug transition-colors ${task.done ? 'line-through text-stone-400' : 'text-stone-700 group-hover:text-stone-900'}`}>
                  {task.label}
                </span>
              </button>
            ))}
          </div>
          {tasks.length > 6 && (
            <Link href="/tasks" className="inline-block text-xs text-teal-700 font-medium mt-2.5 hover:underline">
              +{tasks.length - 6} more →
            </Link>
          )}
        </div>
      </div>

      {/* Location rollup — corporate/brand only */}
      {(role === 'corporate' || role === 'brand') && (
        <div className="bg-white rounded-xl border border-stone-200 overflow-hidden">
          <div className="px-5 py-4 border-b border-stone-100 flex items-center justify-between">
            <h2 className="text-sm font-semibold text-stone-900">Task Completion by Location</h2>
            <span className="text-xs text-stone-500">Today · {LOCATION_DATA.filter(l => l.pct === 100).length}/{LOCATION_DATA.length} complete</span>
          </div>
          <div className="divide-y divide-stone-100">
            {LOCATION_DATA.map(loc => (
              <div key={loc.id} className="px-5 py-3 flex items-center gap-3 hover:bg-stone-50 transition-colors">
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-medium text-stone-900 truncate">{loc.name}</p>
                  <p className="text-xs text-stone-400">{BRANDS[loc.brand].name}</p>
                </div>
                <div className="w-24 bg-stone-100 rounded-full h-1.5 hidden sm:block">
                  <div className="h-1.5 rounded-full" style={{ width: `${loc.pct}%`, backgroundColor: statusColor(loc.pct) }} />
                </div>
                <div className="text-right flex-shrink-0 w-12">
                  <p className="text-sm font-mono font-semibold" style={{ color: statusColor(loc.pct) }}>{loc.pct}%</p>
                  {loc.overdue > 0 && <p className="text-[10px] text-red-500 font-medium">{loc.overdue} late</p>}
                </div>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  )
}
