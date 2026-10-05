'use client'

import { useState } from 'react'
import { useTasks } from '@/hooks/use-tasks'
import { Ring } from '@/components/charts'
import { Ic } from '@/components/icons'
import { TaskModal } from '@/components/tasks/task-modal'
import { BRANDS, DAY_LABELS_CONST, TODAY } from '@/lib/config'
import { formatTime, statusColor } from '@/lib/format'
import { LOCATION_DATA } from '@/lib/mock-data'
import { type Role, type TaskDraft, type TaskEntry } from '@/lib/types'

export function TasksScreen({ role }: { role: Role }) {
  const [view, setView] = useState<'mytasks' | 'rollup'>('mytasks')
  // Tasks now come from the backend API (was: useState(TASKS_DATA))
  const { tasks, loading, error, reload, clearError, createTask, updateTask, toggleTask, deleteTask } = useTasks()
  const [showAddModal, setShowAddModal] = useState(false)
  const [editingTask, setEditingTask] = useState<TaskEntry | null>(null)
  const overdueTasks = tasks.filter(t => !t.done && t.date < TODAY)
  const todayTasks = tasks.filter(t => t.date >= TODAY)
  const doneCount = todayTasks.filter(t => t.done).length
  const pct = todayTasks.length ? Math.round((doneCount / todayTasks.length) * 100) : 0
  const cats = ['Opening', 'Midday', 'Closing'] as const

  function toggle(id: number) {
    void toggleTask(id)
  }

  function addTask(draft: TaskDraft) {
    void createTask(draft)
  }

  function saveEdit(draft: TaskDraft) {
    if (!editingTask) return
    void updateTask(editingTask.id, draft)
  }

  function handleDelete() {
    if (!editingTask) return
    void deleteTask(editingTask.id)
  }

  const canSeeRollup = role === 'corporate' || role === 'brand' || role === 'manager'
  const canManageTasks = role === 'corporate' || role === 'brand' || role === 'manager'

  return (
    <div className="p-4 md:p-6 max-w-4xl mx-auto space-y-4">
      {canManageTasks && showAddModal && <TaskModal onSave={addTask} onClose={() => setShowAddModal(false)} />}
      {canManageTasks && editingTask && <TaskModal initial={editingTask} onSave={saveEdit} onDelete={handleDelete} onClose={() => setEditingTask(null)} />}

      {/* Header — on phones the controls drop to their own full-width row under the title */}
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h1 className="text-xl font-semibold text-stone-900">Tasks</h1>
          <p className="text-xs text-stone-500 mt-0.5">
            {new Date(TODAY + 'T00:00:00').toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric' })}
          </p>
        </div>
        {(canSeeRollup || canManageTasks) && (
        <div className="flex items-center gap-2">
          {canSeeRollup && (
            <div className="bg-stone-100 rounded-lg p-1 flex gap-1 flex-1 sm:flex-none">
              {([['mytasks', 'My Tasks'], ['rollup', 'All Locations']] as const).map(([v, label]) => (
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
          {canManageTasks && (
            <button
              onClick={() => setShowAddModal(true)}
              className="flex items-center justify-center gap-1.5 whitespace-nowrap flex-shrink-0 text-xs font-semibold text-white bg-teal-700 hover:bg-teal-800 active:scale-[0.97] px-3.5 py-2 rounded-lg transition-all"
            >
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2.5} strokeLinecap="round" strokeLinejoin="round" className="w-3.5 h-3.5">
                <line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/>
              </svg>
              Add Task
            </button>
          )}
        </div>
        )}
      </div>

      {/* API status */}
      {error && (
        <div role="alert" className="bg-red-50 border border-red-200 rounded-xl px-4 py-3 flex items-start gap-3">
          <span className="text-red-500 mt-0.5"><Ic.Alert /></span>
          <p className="flex-1 text-sm text-red-700">{error}</p>
          <button onClick={() => { clearError(); void reload() }} className="text-xs font-semibold text-red-700 hover:underline flex-shrink-0">Retry</button>
        </div>
      )}
      {loading && tasks.length === 0 && !error && (
        <div className="bg-white rounded-xl border border-stone-200 p-5 text-sm text-stone-400">Loading tasks…</div>
      )}

      {/* My tasks */}
      {view === 'mytasks' && !(loading && tasks.length === 0) && (
        <>
          <div className="bg-white rounded-xl border border-stone-200 p-5 flex items-center gap-5">
            <Ring pct={pct} size={64} />
            <div>
              <p className="text-3xl font-semibold font-mono text-stone-900">
                {doneCount}<span className="text-base text-stone-400 font-sans font-normal">/{todayTasks.length}</span>
              </p>
              <p className="text-sm text-stone-500 mt-0.5">Tasks complete today</p>
              {doneCount === todayTasks.length
                ? <p className="text-xs text-emerald-600 font-semibold mt-1">All done — great shift!</p>
                : <p className="text-xs text-stone-400 mt-1">{todayTasks.length - doneCount} remaining</p>
              }
            </div>
          </div>

          {/* Overdue tasks */}
          {overdueTasks.length > 0 && (
            <div className="bg-white rounded-xl border border-red-200 overflow-hidden">
              <div className="px-5 py-3 bg-red-50 border-b border-red-100 flex items-center justify-between">
                <div className="flex items-center gap-2">
                  <span className="text-red-500"><Ic.Alert /></span>
                  <p className="text-[11px] font-semibold uppercase tracking-widest text-red-600">Overdue</p>
                </div>
                <p className="text-xs font-mono text-red-400">{overdueTasks.length} task{overdueTasks.length !== 1 ? 's' : ''}</p>
              </div>
              <div className="divide-y divide-red-50">
                {overdueTasks.map(task => (
                  <div
                    key={task.id}
                    onClick={() => canManageTasks && setEditingTask(task as TaskEntry)}
                    className={`flex items-start gap-3.5 px-5 py-3.5 hover:bg-red-50/50 active:bg-red-50 transition-colors group ${canManageTasks ? 'cursor-pointer' : ''}`}
                  >
                    <button
                      onClick={e => { e.stopPropagation(); toggle(task.id) }}
                      className="w-5 h-5 rounded-full flex-shrink-0 flex items-center justify-center border-2 mt-0.5 transition-all duration-150 border-red-300 hover:border-red-500"
                      aria-label="Mark complete"
                    />
                    <div className="flex-1 min-w-0">
                      <span className="text-sm leading-snug text-stone-800 group-hover:text-stone-900">{task.label}</span>
                      <div className="flex items-center gap-2 mt-1 flex-wrap">
                        <span className="text-[10px] font-mono font-semibold text-red-500">Due {task.date}{task.time ? ` · ${formatTime(task.time)}` : ''}</span>
                        <span className="text-[10px] text-stone-400">·</span>
                        <span className="text-[10px] font-semibold text-stone-400 uppercase tracking-wide">{task.cat}</span>
                        {task.recurrence !== 'none' && (
                          <>
                            <span className="text-[10px] text-stone-400">·</span>
                            <span className="text-[10px] font-semibold text-teal-600">
                              ↻ {task.recurrence === 'daily' ? 'Daily' : `Weekly · ${(task.recurrenceDays ?? []).map(d => DAY_LABELS_CONST[d]).join(', ')}`}
                            </span>
                          </>
                        )}
                        {task.attachments.length > 0 && (
                          <>
                            <span className="text-[10px] text-stone-400">·</span>
                            <span className="flex items-center gap-1 text-[10px] text-stone-400">
                              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.75} strokeLinecap="round" strokeLinejoin="round" className="w-3 h-3">
                                <path d="M21.44 11.05l-9.19 9.19a6 6 0 01-8.49-8.49l9.19-9.19a4 4 0 015.66 5.66l-9.2 9.19a2 2 0 01-2.83-2.83l8.49-8.48"/>
                              </svg>
                              {task.attachments.length}
                            </span>
                          </>
                        )}
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}

          {cats.map(cat => {
            const catTasks = todayTasks.filter(t => t.cat === cat)
            if (!catTasks.length) return null
            const catDone = catTasks.filter(t => t.done).length
            return (
              <div key={cat} className="bg-white rounded-xl border border-stone-200 overflow-hidden">
                <div className="px-5 py-3 bg-stone-50 border-b border-stone-100 flex items-center justify-between">
                  <p className="text-[11px] font-semibold uppercase tracking-widest text-stone-400">{cat}</p>
                  <p className="text-xs font-mono text-stone-400">{catDone}/{catTasks.length}</p>
                </div>
                <div className="divide-y divide-stone-100">
                  {catTasks.map(task => (
                    <div
                      key={task.id}
                      onClick={() => canManageTasks && setEditingTask(task as TaskEntry)}
                      className={`flex items-start gap-3.5 px-5 py-3.5 hover:bg-stone-50 active:bg-stone-100 transition-colors group ${canManageTasks ? 'cursor-pointer' : ''}`}
                    >
                      {/* Checkbox — click only toggles, does not open edit */}
                      <button
                        onClick={e => { e.stopPropagation(); toggle(task.id) }}
                        className={`w-5 h-5 rounded-full flex-shrink-0 flex items-center justify-center border-2 mt-0.5 transition-all duration-150 ${task.done ? 'bg-teal-700 border-teal-700' : 'border-stone-300 hover:border-teal-500'}`}
                        aria-label={task.done ? 'Mark incomplete' : 'Mark complete'}
                      >
                        {task.done && (
                          <svg viewBox="0 0 12 12" fill="none" stroke="white" strokeWidth={2.5} strokeLinecap="round" strokeLinejoin="round" className="w-3 h-3">
                            <polyline points="1.5 6 4.5 9 10.5 3" />
                          </svg>
                        )}
                      </button>

                      {/* Text + meta */}
                      <div className="flex-1 min-w-0">
                        <span className={`text-sm leading-snug transition-colors ${task.done ? 'line-through text-stone-400' : 'text-stone-800 group-hover:text-stone-900'}`}>
                          {task.label}
                        </span>
                        {(task.time || task.recurrence !== 'none' || task.attachments.length > 0) && (
                          <div className="flex items-center gap-2 mt-1 flex-wrap">
                            {task.time && (
                              <span className="text-[10px] font-mono text-stone-400">{formatTime(task.time)}</span>
                            )}
                            {task.recurrence !== 'none' && (
                              <>
                                {task.time && <span className="text-[10px] text-stone-300">·</span>}
                                <span className="text-[10px] font-semibold text-teal-600">
                                  ↻ {task.recurrence === 'daily' ? 'Daily' : `Weekly · ${(task.recurrenceDays ?? []).map(d => DAY_LABELS_CONST[d]).join(', ')}`}
                                </span>
                              </>
                            )}
                            {task.attachments.length > 0 && (
                              <>
                                {(task.time || task.recurrence !== 'none') && <span className="text-[10px] text-stone-300">·</span>}
                                <span className="flex items-center gap-1 text-[10px] text-stone-400">
                                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.75} strokeLinecap="round" strokeLinejoin="round" className="w-3 h-3">
                                    <path d="M21.44 11.05l-9.19 9.19a6 6 0 01-8.49-8.49l9.19-9.19a4 4 0 015.66 5.66l-9.2 9.19a2 2 0 01-2.83-2.83l8.49-8.48"/>
                                  </svg>
                                  {task.attachments.length} attachment{task.attachments.length !== 1 ? 's' : ''}
                                </span>
                              </>
                            )}
                          </div>
                        )}
                      </div>

                    </div>
                  ))}
                </div>
              </div>
            )
          })}
        </>
      )}

      {/* Rollup */}
      {view === 'rollup' && (
        <div className="bg-white rounded-xl border border-stone-200 overflow-hidden">
          <div className="px-5 py-4 border-b border-stone-100 flex items-center justify-between">
            <h2 className="text-sm font-semibold text-stone-900">All Locations — Today</h2>
            <span className="text-xs text-stone-500">
              {LOCATION_DATA.filter(l => l.pct === 100).length}/{LOCATION_DATA.length} fully complete
            </span>
          </div>
          <div className="hidden md:grid px-5 py-2.5 bg-stone-50 border-b border-stone-100 gap-4 text-[10px] font-semibold uppercase tracking-widest text-stone-400"
            style={{ gridTemplateColumns: '1fr 72px 72px 72px 56px' }}>
            <span>Location</span>
            <span className="text-right">Done</span>
            <span className="text-right">Total</span>
            <span className="text-right">Overdue</span>
            <span className="text-right">%</span>
          </div>
          <div className="divide-y divide-stone-100">
            {[...LOCATION_DATA].sort((a, b) => a.pct - b.pct).map(loc => (
              <div
                key={loc.id}
                className="px-5 py-3.5 flex md:grid items-center gap-3 md:gap-4 hover:bg-stone-50 transition-colors"
                style={{ gridTemplateColumns: '1fr 72px 72px 72px 56px' }}
              >
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-medium text-stone-900 truncate">{loc.name}</p>
                  <div className="flex items-center gap-2 mt-0.5">
                    <span className="text-xs text-stone-400">{BRANDS[loc.brand].name}</span>
                    <div className="flex-1 bg-stone-100 rounded-full h-1 max-w-[60px] md:hidden">
                      <div className="h-1 rounded-full" style={{ width: `${loc.pct}%`, backgroundColor: statusColor(loc.pct) }} />
                    </div>
                  </div>
                </div>
                <span className="hidden md:block text-sm font-mono text-stone-700 text-right">{loc.done}</span>
                <span className="hidden md:block text-sm font-mono text-stone-400 text-right">{loc.total}</span>
                <span className={`text-sm font-mono text-right font-semibold ${loc.overdue > 0 ? 'text-red-600' : 'text-stone-300'}`}>
                  {loc.overdue > 0 ? loc.overdue : '—'}
                </span>
                <span className="text-sm font-mono font-bold text-right" style={{ color: statusColor(loc.pct) }}>
                  {loc.pct}%
                </span>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  )
}
