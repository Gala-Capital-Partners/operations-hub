'use client'

import { useEffect, useMemo, useState } from 'react'
import { Ring } from '@/components/charts'
import { Ic } from '@/components/icons'
import type { Account } from '@/components/session-provider'
import { CreateTaskDialog } from '@/components/tasks/create-task-dialog'
import { TaskInstanceDialog } from '@/components/tasks/task-instance-dialog'
import { useTaskInstances } from '@/hooks/use-task-instances'
import { addDays, localTimeOf, localToday, taskInstancesApi, type TaskInstance } from '@/lib/api/task-instances'
import { brandLocations, canAtLocation } from '@/lib/auth'
import { formatTime, statusColor } from '@/lib/format'

const CATEGORIES = ['Opening', 'Midday', 'Closing'] as const

function prettyDate(date: string) {
  return new Date(`${date}T00:00:00Z`).toLocaleDateString('en-US', { timeZone: 'UTC', weekday: 'long', month: 'long', day: 'numeric' })
}

function whenLabel(task: TaskInstance) {
  if (!task.isAllDay) return localTimeOf(task)
  return task.dueTime ? `Due ${formatTime(task.dueTime.slice(0, 5))}` : null
}

/**
 * Tasks screen for signed-in (Supabase) users: real task instances from
 * GET /api/task-instances for one location and store-local day, with complete and
 * reopen through the API.
 */
export function TasksDbScreen({ account, brand }: { account: Account; brand: string }) {
  const locations = useMemo(() => brandLocations(account, brand), [account, brand])

  const [locationId, setLocationId] = useState<string | null>(locations[0]?.id ?? null)
  const location = locations.find(l => l.id === locationId) ?? null
  const today = location ? localToday(location.timezone) : null
  const [date, setDate] = useState<string | null>(today)
  const [view, setView] = useState<'mytasks' | 'rollup'>('mytasks')
  const [openTaskId, setOpenTaskId] = useState<string | null>(null)
  const [creating, setCreating] = useState(false)
  const [notice, setNotice] = useState<string | null>(null)

  // Switching brand changes the available locations; switching location resets to its "today".
  useEffect(() => {
    if (!locations.some(l => l.id === locationId)) {
      // eslint-disable-next-line react-hooks/set-state-in-effect
      setLocationId(locations[0]?.id ?? null)
    }
  }, [locations, locationId])
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setDate(location ? localToday(location.timezone) : null)
  }, [location?.id]) // eslint-disable-line react-hooks/exhaustive-deps

  const viewingToday = date !== null && date === today
  const { tasks, overdue, loading, error, clearError, reload, complete, reopen, pendingIds } = useTaskInstances(
    locationId,
    date ?? '',
    viewingToday,
  )

  const canComplete = !!locationId && canAtLocation(account, 'task_instances.complete', locationId)
  const canReopen = !!locationId && canAtLocation(account, 'task_instances.reopen', locationId)
  // Creating tasks needs tasks.manage at this store; brand-wide tasks need it for the whole brand.
  const canCreate = !!locationId && canAtLocation(account, 'tasks.manage', locationId)
  const brandInfo = account.brands.find(b => b.slug === brand) ?? null
  const canCreateBrandWide = (account.permissions ?? []).some(
    p => p.permission === 'tasks.manage' && (p.scope === 'organization' || (p.scope === 'brand' && p.brandId === brandInfo?.id)),
  )
  const doneCount = tasks.filter(t => t.completedAt).length
  const pct = tasks.length ? Math.round((doneCount / tasks.length) * 100) : 0
  const openTask = [...tasks, ...overdue].find(t => t.id === openTaskId) ?? null

  function toggle(task: TaskInstance) {
    if (task.completedAt) {
      if (canReopen) void reopen(task)
      else setOpenTaskId(task.id)
      return
    }
    if (!canComplete) return setOpenTaskId(task.id)
    // Tasks that take a reading open the dialog so the value can be entered.
    if (task.numericUnit) return setOpenTaskId(task.id)
    void complete(task, {}, account.userId)
  }

  if (!location || !date) {
    return (
      <div className="p-4 md:p-6 max-w-4xl mx-auto">
        <h1 className="text-xl font-semibold text-stone-900">Tasks</h1>
        <p className="mt-4 text-sm text-stone-500 bg-white rounded-xl border border-stone-200 p-5">You don&apos;t have access to any locations in this brand.</p>
      </div>
    )
  }

  const row = (task: TaskInstance, tone: 'normal' | 'overdue') => {
    const done = !!task.completedAt
    const pending = pendingIds.has(task.id)
    const when = whenLabel(task)
    return (
      <div
        key={task.id}
        data-task-id={task.id}
        onClick={() => setOpenTaskId(task.id)}
        className={`flex items-start gap-3.5 px-5 py-3.5 transition-colors group cursor-pointer ${tone === 'overdue' ? 'hover:bg-red-50/50' : 'hover:bg-stone-50'}`}
      >
        <button
          onClick={e => { e.stopPropagation(); toggle(task) }}
          disabled={pending || (!done && !canComplete) || (done && !canReopen)}
          className={`w-5 h-5 rounded-full flex-shrink-0 flex items-center justify-center border-2 mt-0.5 transition-all duration-150 disabled:cursor-default ${
            done ? 'bg-teal-700 border-teal-700' : tone === 'overdue' ? 'border-red-300 hover:border-red-500' : 'border-stone-300 hover:border-teal-500'
          } ${pending ? 'opacity-50' : ''}`}
          aria-label={done ? 'Reopen task' : 'Mark complete'}
        >
          {done && (
            <svg viewBox="0 0 12 12" fill="none" stroke="white" strokeWidth={2.5} strokeLinecap="round" strokeLinejoin="round" className="w-3 h-3">
              <polyline points="1.5 6 4.5 9 10.5 3" />
            </svg>
          )}
        </button>
        <div className="flex-1 min-w-0">
          <span className={`text-sm leading-snug ${done ? 'line-through text-stone-400' : 'text-stone-800 group-hover:text-stone-900'}`}>{task.name}</span>
          <div className="flex items-center gap-2 mt-1 flex-wrap text-[10px]">
            {tone === 'overdue' && <span className="font-mono font-semibold text-red-500">{task.scheduledDay}</span>}
            {when && <span className="font-mono text-stone-400">{when}</span>}
            {tone === 'overdue' && <span className="font-semibold text-stone-400 uppercase tracking-wide">{task.category}</span>}
            {task.numericUnit && (
              <span className="font-semibold text-teal-600">
                {task.recordedValue !== null ? `${task.recordedValue} ${task.numericUnit}` : `Reading · ${task.numericUnit}`}
              </span>
            )}
            {task.notes && <span className="text-stone-400">· Note</span>}
          </div>
        </div>
      </div>
    )
  }

  return (
    <div className="p-4 md:p-6 max-w-4xl mx-auto space-y-4">
      {creating && brandInfo && today && (
        <CreateTaskDialog
          brand={brandInfo}
          location={location}
          canCreateBrandWide={canCreateBrandWide}
          today={today}
          onClose={() => setCreating(false)}
          onCreated={name => {
            setCreating(false)
            setNotice(`“${name}” was created. Days in the coming week appear on the checklist now; later days are added automatically.`)
            void reload()
          }}
        />
      )}

      {openTask && (
        <TaskInstanceDialog
          key={openTask.id}
          task={openTask}
          currentUserId={account.userId}
          canComplete={canComplete}
          canReopen={canReopen}
          busy={pendingIds.has(openTask.id)}
          onClose={() => setOpenTaskId(null)}
          onComplete={async input => {
            const ok = await complete(openTask, input, account.userId)
            if (ok) setOpenTaskId(null)
          }}
          onReopen={async () => {
            const ok = await reopen(openTask)
            if (ok) setOpenTaskId(null)
          }}
        />
      )}

      {/* Header */}
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h1 className="text-xl font-semibold text-stone-900">Tasks</h1>
            <p className="text-xs text-stone-500 mt-0.5">
              {location.name}{location.storeNumber ? ` · ${location.storeNumber}` : ''}
            </p>
          </div>
          {canCreate && brandInfo && (
            <button
              onClick={() => { setNotice(null); setCreating(true) }}
              className="px-3 py-1.5 rounded-lg text-xs font-semibold text-white bg-teal-700 hover:opacity-90 flex-shrink-0"
            >
              + New task
            </button>
          )}
        </div>
        {locations.length > 1 && (
          <div className="bg-stone-100 rounded-lg p-1 flex gap-1 flex-1 sm:flex-none">
            {([['mytasks', 'Location'], ['rollup', 'All Locations']] as const).map(([v, label]) => (
              <button
                key={v}
                onClick={() => setView(v)}
                className={`flex-1 sm:flex-none whitespace-nowrap px-3 py-1.5 rounded text-xs font-semibold transition-all ${view === v ? 'bg-white text-stone-900 shadow-sm' : 'text-stone-500 hover:text-stone-700'}`}
              >
                {label}
              </button>
            ))}
          </div>
        )}
      </div>

      {notice && (
        <div role="status" className="bg-emerald-50 border border-emerald-200 rounded-xl px-4 py-2.5 flex items-start gap-3">
          <p className="flex-1 text-sm text-emerald-800">{notice}</p>
          <button onClick={() => setNotice(null)} className="text-xs font-semibold text-emerald-800 hover:underline">Dismiss</button>
        </div>
      )}

      {view === 'mytasks' && (
        <>
          {/* Location + day controls */}
          <div className="bg-white rounded-xl border border-stone-200 px-4 py-3 flex flex-col sm:flex-row sm:items-center gap-3">
            {locations.length > 1 && (
              <label className="flex items-center gap-2 text-xs font-semibold text-stone-500">
                Location
                <select
                  value={location.id}
                  onChange={e => setLocationId(e.target.value)}
                  className="border border-stone-200 rounded-lg px-2 py-1.5 text-sm font-normal text-stone-800 bg-white focus:outline-none focus:border-teal-600"
                >
                  {locations.map(l => (
                    <option key={l.id} value={l.id}>{l.storeNumber ? `${l.storeNumber} · ` : ''}{l.name}</option>
                  ))}
                </select>
              </label>
            )}
            <div className="flex items-center gap-1 sm:ml-auto">
              <button onClick={() => setDate(addDays(date, -1))} aria-label="Previous day" className="p-1.5 rounded-lg text-stone-500 hover:bg-stone-100"><Ic.ChevronLeft /></button>
              <span className="text-sm font-medium text-stone-800 min-w-[11rem] text-center" data-testid="task-date">{prettyDate(date)}</span>
              <button onClick={() => setDate(addDays(date, 1))} aria-label="Next day" className="p-1.5 rounded-lg text-stone-500 hover:bg-stone-100"><Ic.ChevronRight /></button>
              {!viewingToday && (
                <button onClick={() => setDate(today)} className="ml-1 text-xs font-semibold text-teal-700 hover:underline">Today</button>
              )}
            </div>
          </div>

          {!canComplete && (
            <p className="text-xs text-stone-500 bg-stone-50 border border-stone-200 rounded-xl px-4 py-2.5">
              View only: tasks are completed by the team at each location.
            </p>
          )}

          {error && (
            <div role="alert" className="bg-red-50 border border-red-200 rounded-xl px-4 py-3 flex items-start gap-3">
              <span className="text-red-500 mt-0.5"><Ic.Alert /></span>
              <p className="flex-1 text-sm text-red-700">{error}</p>
              <button onClick={() => { clearError(); void reload() }} className="text-xs font-semibold text-red-700 hover:underline flex-shrink-0">Retry</button>
            </div>
          )}

          {loading && tasks.length === 0 && !error ? (
            <div className="bg-white rounded-xl border border-stone-200 p-5 text-sm text-stone-400">Loading tasks…</div>
          ) : (
            <>
              <div className="bg-white rounded-xl border border-stone-200 p-5 flex items-center gap-5">
                <Ring pct={pct} size={64} />
                <div>
                  <p className="text-3xl font-semibold font-mono text-stone-900" data-testid="task-progress">
                    {doneCount}<span className="text-base text-stone-400 font-sans font-normal">/{tasks.length}</span>
                  </p>
                  <p className="text-sm text-stone-500 mt-0.5">{viewingToday ? 'Tasks complete today' : 'Tasks complete'}</p>
                  {tasks.length > 0 && (doneCount === tasks.length
                    ? <p className="text-xs text-emerald-600 font-semibold mt-1">All done — great shift!</p>
                    : <p className="text-xs text-stone-400 mt-1">{tasks.length - doneCount} remaining</p>)}
                </div>
              </div>

              {viewingToday && overdue.length > 0 && (
                <div className="bg-white rounded-xl border border-red-200 overflow-hidden">
                  <div className="px-5 py-3 bg-red-50 border-b border-red-100 flex items-center justify-between">
                    <div className="flex items-center gap-2">
                      <span className="text-red-500"><Ic.Alert /></span>
                      <p className="text-[11px] font-semibold uppercase tracking-widest text-red-600">Still open from yesterday</p>
                    </div>
                    <p className="text-xs font-mono text-red-400">{overdue.length} task{overdue.length !== 1 ? 's' : ''}</p>
                  </div>
                  <div className="divide-y divide-red-50">{overdue.map(t => row(t, 'overdue'))}</div>
                </div>
              )}

              {tasks.length === 0 && !error && (
                <p className="bg-white rounded-xl border border-stone-200 p-5 text-sm text-stone-500">No tasks scheduled for this day.</p>
              )}

              {CATEGORIES.map(cat => {
                const catTasks = tasks.filter(t => t.category === cat)
                if (!catTasks.length) return null
                return (
                  <div key={cat} className="bg-white rounded-xl border border-stone-200 overflow-hidden">
                    <div className="px-5 py-3 bg-stone-50 border-b border-stone-100 flex items-center justify-between">
                      <p className="text-[11px] font-semibold uppercase tracking-widest text-stone-400">{cat}</p>
                      <p className="text-xs font-mono text-stone-400">{catTasks.filter(t => t.completedAt).length}/{catTasks.length}</p>
                    </div>
                    <div className="divide-y divide-stone-100">{catTasks.map(t => row(t, 'normal'))}</div>
                  </div>
                )
              })}

              <p className="text-xs text-stone-400 text-center">Editing task isn&apos;t available yet.</p>
            </>
          )}
        </>
      )}

      {view === 'rollup' && <Rollup locations={locations} onOpen={id => { setLocationId(id); setView('mytasks') }} />}
    </div>
  )
}

type RollupRow = { id: string; name: string; storeNumber: string | null; done: number; total: number; overdue: number; error?: string }

/** Today's completion for every location in the brand (two list requests per location). */
function Rollup({ locations, onOpen }: { locations: Account['locations']; onOpen: (id: string) => void }) {
  const [rows, setRows] = useState<RollupRow[] | null>(null)

  useEffect(() => {
    let cancelled = false
    Promise.all(
      locations.map(async (l): Promise<RollupRow> => {
        const day = localToday(l.timezone)
        try {
          const [today, yesterday] = await Promise.all([taskInstancesApi.list(l.id, day), taskInstancesApi.list(l.id, addDays(day, -1))])
          return {
            id: l.id, name: l.name, storeNumber: l.storeNumber,
            done: today.filter(t => t.completedAt).length,
            total: today.length,
            overdue: yesterday.filter(t => !t.completedAt).length,
          }
        } catch (err) {
          return { id: l.id, name: l.name, storeNumber: l.storeNumber, done: 0, total: 0, overdue: 0, error: err instanceof Error ? err.message : 'Failed to load' }
        }
      }),
    ).then(result => !cancelled && setRows(result))
    return () => { cancelled = true }
  }, [locations])

  if (!rows) return <div className="bg-white rounded-xl border border-stone-200 p-5 text-sm text-stone-400">Loading locations…</div>

  const pctOf = (r: RollupRow) => (r.total ? Math.round((r.done / r.total) * 100) : 0)
  const complete = rows.filter(r => r.total > 0 && r.done === r.total).length
  return (
    <div className="bg-white rounded-xl border border-stone-200 overflow-hidden">
      <div className="px-5 py-4 border-b border-stone-100 flex items-center justify-between">
        <h2 className="text-sm font-semibold text-stone-900">All Locations — Today</h2>
        <span className="text-xs text-stone-500">{complete}/{rows.length} fully complete</span>
      </div>
      <div className="hidden md:grid px-5 py-2.5 bg-stone-50 border-b border-stone-100 gap-4 text-[10px] font-semibold uppercase tracking-widest text-stone-400"
        style={{ gridTemplateColumns: '1fr 72px 72px 96px 56px' }}>
        <span>Location</span><span className="text-right">Done</span><span className="text-right">Total</span>
        <span className="text-right">Open (yday)</span><span className="text-right">%</span>
      </div>
      <div className="divide-y divide-stone-100">
        {[...rows].sort((a, b) => pctOf(a) - pctOf(b)).map(r => (
          <button
            key={r.id}
            onClick={() => onOpen(r.id)}
            className="w-full text-left px-5 py-3.5 flex md:grid items-center gap-3 md:gap-4 hover:bg-stone-50 transition-colors"
            style={{ gridTemplateColumns: '1fr 72px 72px 96px 56px' }}
            data-testid="rollup-row"
          >
            <div className="flex-1 min-w-0">
              <p className="text-sm font-medium text-stone-900 truncate">{r.name}</p>
              <p className="text-xs text-stone-400">{r.error ?? r.storeNumber}</p>
            </div>
            <span className="hidden md:block text-sm font-mono text-stone-700 text-right">{r.done}</span>
            <span className="hidden md:block text-sm font-mono text-stone-400 text-right">{r.total}</span>
            <span className={`text-sm font-mono text-right font-semibold ${r.overdue > 0 ? 'text-red-600' : 'text-stone-300'}`}>{r.overdue > 0 ? r.overdue : '—'}</span>
            <span className="text-sm font-mono font-bold text-right" style={{ color: statusColor(pctOf(r)) }}>{pctOf(r)}%</span>
          </button>
        ))}
      </div>
    </div>
  )
}
