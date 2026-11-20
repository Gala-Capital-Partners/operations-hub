'use client'

import { useState, type FormEvent } from 'react'
import { localTimeOf, type CompleteInput, type TaskInstance } from '@/lib/api/task-instances'
import { formatTime } from '@/lib/format'

/**
 * Details for one database task instance. Lets permitted users complete it with an
 * optional reading and notes, or reopen it. All text is rendered as plain text.
 */
export function TaskInstanceDialog({
  task,
  currentUserId,
  canComplete,
  canReopen,
  busy,
  onComplete,
  onReopen,
  onClose,
}: {
  task: TaskInstance
  currentUserId: string
  canComplete: boolean
  canReopen: boolean
  busy: boolean
  onComplete: (input: CompleteInput) => void
  onReopen: () => void
  onClose: () => void
}) {
  const done = task.completedAt !== null
  const numeric = task.numericUnit !== null
  const [reading, setReading] = useState('')
  const [notes, setNotes] = useState('')
  const [formError, setFormError] = useState<string | null>(null)

  const bounds =
    task.numericMin !== null && task.numericMax !== null
      ? `${task.numericMin} to ${task.numericMax} ${task.numericUnit}`
      : null

  function submit(e: FormEvent) {
    e.preventDefault()
    let recordedValue: number | null = null
    if (numeric && reading.trim() !== '') {
      recordedValue = Number(reading)
      if (!Number.isFinite(recordedValue)) return setFormError('Enter a number.')
      if (task.numericMin !== null && recordedValue < task.numericMin) return setFormError(`Must be at least ${task.numericMin}.`)
      if (task.numericMax !== null && recordedValue > task.numericMax) return setFormError(`Must be at most ${task.numericMax}.`)
    }
    if (notes.length > 2000) return setFormError('Notes can be at most 2,000 characters.')
    setFormError(null)
    onComplete({ recordedValue, notes: notes.trim() === '' ? null : notes })
  }

  const when = task.isAllDay ? (task.dueTime ? `Due ${formatTime(task.dueTime.slice(0, 5))}` : 'Any time today') : localTimeOf(task)

  return (
    <div className="fixed inset-0 z-50 flex items-end md:items-center justify-center p-4" role="dialog" aria-modal="true" aria-labelledby="task-dialog-title">
      <div className="absolute inset-0 bg-black/30" onClick={onClose} />
      <div className="relative bg-white rounded-2xl shadow-xl w-full max-w-md max-h-[90vh] overflow-y-auto">
        <div className="px-5 pt-5 pb-3 border-b border-stone-100">
          <p className="text-[10px] font-semibold uppercase tracking-widest text-stone-400">{task.category} · {when}</p>
          <h2 id="task-dialog-title" className="text-base font-semibold text-stone-900 mt-1">{task.name}</h2>
          {task.description && <p className="text-sm text-stone-500 mt-1 whitespace-pre-line">{task.description}</p>}
        </div>

        {done ? (
          <div className="px-5 py-4 space-y-2 text-sm">
            <p className="text-emerald-700 font-semibold">
              Completed {task.completedBy === currentUserId ? 'by you' : 'by a team member'}
              {task.completedAt && (
                <span className="text-stone-400 font-normal">
                  {' '}· {new Intl.DateTimeFormat('en-US', { timeZone: task.timezone, month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(new Date(task.completedAt))}
                </span>
              )}
            </p>
            {task.recordedValue !== null && (
              <p className="text-stone-700">Reading: <span className="font-mono font-semibold">{task.recordedValue} {task.numericUnit}</span></p>
            )}
            {task.notes && <p className="text-stone-700 whitespace-pre-line bg-stone-50 rounded-lg px-3 py-2">{task.notes}</p>}
            {!canReopen && <p className="text-xs text-stone-400">Only a location manager can reopen a completed task.</p>}
          </div>
        ) : canComplete ? (
          <form id="complete-form" onSubmit={submit} className="px-5 py-4 space-y-3">
            {numeric && (
              <div>
                <label htmlFor="task-reading" className="block text-xs font-semibold text-stone-500 uppercase tracking-wide mb-1.5">
                  Reading ({task.numericUnit}) <span className="normal-case font-normal text-stone-400">· optional</span>
                </label>
                <input
                  id="task-reading"
                  inputMode="decimal"
                  value={reading}
                  onChange={e => setReading(e.target.value)}
                  placeholder={bounds ? `Allowed: ${bounds}` : undefined}
                  className="w-full border border-stone-200 rounded-xl px-3 py-2 text-sm font-mono focus:outline-none focus:border-teal-600 focus:ring-2 focus:ring-teal-600/20"
                />
              </div>
            )}
            <div>
              <label htmlFor="task-notes" className="block text-xs font-semibold text-stone-500 uppercase tracking-wide mb-1.5">
                Notes <span className="normal-case font-normal text-stone-400">· optional</span>
              </label>
              <textarea
                id="task-notes"
                rows={3}
                value={notes}
                onChange={e => setNotes(e.target.value)}
                className="w-full border border-stone-200 rounded-xl px-3 py-2 text-sm focus:outline-none focus:border-teal-600 focus:ring-2 focus:ring-teal-600/20 resize-none"
              />
            </div>
            {formError && <p role="alert" className="text-sm text-red-700">{formError}</p>}
          </form>
        ) : (
          <p className="px-5 py-4 text-sm text-stone-500">Not completed yet. Store teams complete tasks at their location.</p>
        )}

        <div className="px-5 py-3 border-t border-stone-100 flex justify-end gap-2">
          <button onClick={onClose} className="px-3.5 py-2 rounded-lg text-xs font-semibold text-stone-600 hover:bg-stone-100">Close</button>
          {done && canReopen && (
            <button onClick={onReopen} disabled={busy} className="px-3.5 py-2 rounded-lg text-xs font-semibold text-white bg-stone-700 hover:bg-stone-800 disabled:opacity-60">
              Reopen task
            </button>
          )}
          {!done && canComplete && (
            <button type="submit" form="complete-form" disabled={busy} className="px-3.5 py-2 rounded-lg text-xs font-semibold text-white bg-teal-700 hover:bg-teal-800 disabled:opacity-60">
              Mark complete
            </button>
          )}
        </div>
      </div>
    </div>
  )
}
