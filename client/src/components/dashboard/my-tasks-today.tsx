'use client'

import Link from 'next/link'
import { Ring } from '@/components/charts'
import { useTaskInstances } from '@/hooks/use-task-instances'
import { localTimeOf, localToday, type TaskInstance } from '@/lib/api/task-instances'

const VISIBLE = 6

export type HomeLocation = { id: string; name: string; timezone: string }

/**
 * Read-only summary of one store's checklist for the store's local today, from
 * GET /api/task-instances. Completing (with readings/notes) happens on the Tasks page.
 */
export function MyTasksToday({ location }: { location: HomeLocation }) {
  const today = localToday(location.timezone)
  const { tasks, loading, error, reload } = useTaskInstances(location.id, today, false)
  const done = tasks.filter(t => t.completedAt).length
  const pct = tasks.length ? Math.round((done / tasks.length) * 100) : 0

  return (
    <section aria-labelledby="my-tasks-heading" className="bg-white rounded-xl border border-stone-200 p-5">
      <div className="flex items-start justify-between mb-4">
        <div>
          <h2 id="my-tasks-heading" className="text-sm font-semibold text-stone-900">My Tasks Today</h2>
          <p className="text-xs text-stone-500 mt-0.5">
            {location.name}
            {!loading && !error && tasks.length > 0 && ` · ${done} of ${tasks.length} complete`}
          </p>
        </div>
        {tasks.length > 0 && <Ring pct={pct} size={44} />}
      </div>

      {error ? (
        <div role="alert" className="flex items-center justify-between gap-3 bg-red-50 rounded-lg px-3 py-2">
          <p className="text-sm text-red-700">{error}</p>
          <button onClick={() => void reload()} className="text-xs font-medium text-red-700 underline flex-shrink-0">
            Try again
          </button>
        </div>
      ) : loading && tasks.length === 0 ? (
        <p className="text-sm text-stone-500">Loading tasks…</p>
      ) : tasks.length === 0 ? (
        <p className="text-sm text-stone-500">No tasks scheduled today.</p>
      ) : (
        <ul className="space-y-1">
          {tasks.slice(0, VISIBLE).map(task => (
            <TaskRow key={task.id} task={task} />
          ))}
        </ul>
      )}

      <Link href="/tasks" className="inline-block text-xs text-teal-700 font-medium mt-3 hover:underline">
        {tasks.length > VISIBLE ? `+${tasks.length - VISIBLE} more · open checklist →` : 'Open checklist →'}
      </Link>
    </section>
  )
}

function TaskRow({ task }: { task: TaskInstance }) {
  const done = task.completedAt !== null
  return (
    <li className="flex items-start gap-2.5 py-1.5">
      <span
        aria-hidden
        className={`w-4 h-4 rounded-full flex-shrink-0 flex items-center justify-center border-2 mt-0.5 ${done ? 'bg-teal-700 border-teal-700' : 'border-stone-300'}`}
      >
        {done && (
          <svg viewBox="0 0 10 10" fill="none" stroke="white" strokeWidth={2.5} strokeLinecap="round" strokeLinejoin="round" className="w-2.5 h-2.5">
            <polyline points="1.5 5 3.5 7.5 8.5 2.5" />
          </svg>
        )}
      </span>
      <span className={`flex-1 text-sm leading-snug ${done ? 'line-through text-stone-400' : 'text-stone-700'}`}>
        {task.name}
        <span className="sr-only">{done ? ' (done)' : ' (open)'}</span>
      </span>
      {!task.isAllDay && <span className="text-xs text-stone-400 flex-shrink-0">{localTimeOf(task)}</span>}
    </li>
  )
}
