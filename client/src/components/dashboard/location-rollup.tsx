'use client'

import { useTaskSummary } from '@/hooks/use-task-summary'
import type { TaskSummary } from '@/lib/api/task-instances'
import { statusColor } from '@/lib/format'

/** Live manager rollup: task completion for every store the user can read. */
export function LocationRollup({ date }: { date: string }) {
  const { summary, loading, error, reload } = useTaskSummary(date)
  return <LocationRollupView date={date} summary={summary} loading={loading} error={error} onRetry={() => void reload()} />
}

export function LocationRollupView({
  date,
  summary,
  loading,
  error,
  onRetry,
}: {
  date: string
  summary: TaskSummary | null
  loading: boolean
  error: string | null
  onRetry: () => void
}) {
  const locations = summary?.locations ?? []
  const finished = locations.filter(l => l.total > 0 && l.remaining === 0).length
  const dayLabel = new Date(`${date}T00:00:00`).toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' })

  return (
    <section aria-labelledby="rollup-heading" className="bg-white rounded-xl border border-stone-200 overflow-hidden">
      <div className="px-5 py-4 border-b border-stone-100 flex flex-col gap-1 sm:flex-row sm:items-center sm:justify-between sm:gap-3">
        <div>
          <h2 id="rollup-heading" className="text-sm font-semibold text-stone-900">Task Completion by Location</h2>
          {summary && (
            <p className="text-xs text-stone-500 mt-0.5">
              {summary.totals.completed} of {summary.totals.total} tasks done
              {summary.totals.locationsWithoutTasks > 0 &&
                ` · ${summary.totals.locationsWithoutTasks} ${summary.totals.locationsWithoutTasks === 1 ? 'store has' : 'stores have'} no tasks`}
            </p>
          )}
        </div>
        <span className="text-xs text-stone-500 sm:flex-shrink-0">
          {dayLabel}
          {locations.length > 0 && ` · ${finished}/${locations.length} stores complete`}
        </span>
      </div>

      {error ? (
        <div role="alert" className="px-5 py-4 flex items-center justify-between gap-3 bg-red-50">
          <p className="text-sm text-red-700">{error}</p>
          <button onClick={onRetry} className="text-xs font-medium text-red-700 underline flex-shrink-0">
            Try again
          </button>
        </div>
      ) : loading && !summary ? (
        <p className="px-5 py-4 text-sm text-stone-500">Loading stores…</p>
      ) : locations.length === 0 ? (
        <p className="px-5 py-4 text-sm text-stone-500">You don’t have access to any stores yet.</p>
      ) : (
        <ul className="divide-y divide-stone-100">
          {locations.map(loc => {
            const pct = loc.total ? Math.round((loc.completed / loc.total) * 100) : 0
            return (
              <li key={loc.locationId} className="px-5 py-3 flex items-center gap-3">
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-medium text-stone-900 truncate">
                    {loc.locationName}
                    {loc.storeNumber && <span className="text-stone-400 font-normal"> · #{loc.storeNumber}</span>}
                  </p>
                  <p className="text-xs text-stone-400">{loc.brandName}</p>
                </div>
                {loc.total === 0 ? (
                  <span className="text-[11px] font-medium text-amber-700 bg-amber-50 border border-amber-200 rounded-full px-2 py-0.5 flex-shrink-0">
                    No tasks scheduled
                  </span>
                ) : (
                  <>
                    <div
                      className="w-24 bg-stone-100 rounded-full h-1.5 hidden sm:block"
                      role="progressbar"
                      aria-label={`${loc.locationName} completion`}
                      aria-valuenow={pct}
                      aria-valuemin={0}
                      aria-valuemax={100}
                    >
                      <div className="h-1.5 rounded-full" style={{ width: `${pct}%`, backgroundColor: statusColor(pct) }} />
                    </div>
                    <div className="text-right flex-shrink-0 w-20">
                      <p className="text-sm font-mono font-semibold" style={{ color: statusColor(pct) }}>{pct}%</p>
                      <p className="text-[10px] text-stone-500">
                        {loc.remaining > 0 ? `${loc.remaining} open` : 'All done'} · {loc.completed}/{loc.total}
                      </p>
                    </div>
                  </>
                )}
              </li>
            )
          })}
        </ul>
      )}
    </section>
  )
}
