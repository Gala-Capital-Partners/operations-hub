'use client'

import { useCallback, useEffect, useRef, useState } from 'react'
import {
  addDays,
  taskInstancesApi,
  TaskApiError,
  type CompleteInput,
  type CompletionResult,
  type TaskInstance,
} from '@/lib/api/task-instances'

/**
 * Database task instances for one location and day, plus the previous day's
 * unfinished tasks when `includeOverdue` is set (shown as "Still open from yesterday").
 * Complete/reopen update the row optimistically and roll back if the API rejects it.
 */
export function useTaskInstances(locationId: string | null, date: string, includeOverdue: boolean) {
  const [tasks, setTasks] = useState<TaskInstance[]>([])
  const [overdue, setOverdue] = useState<TaskInstance[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [pendingIds, setPendingIds] = useState<Set<string>>(new Set())
  const requestRef = useRef(0)

  const reload = useCallback(async () => {
    if (!locationId) return
    const requestId = ++requestRef.current
    setLoading(true)
    try {
      const [day, previous] = await Promise.all([
        taskInstancesApi.list(locationId, date),
        includeOverdue ? taskInstancesApi.list(locationId, addDays(date, -1)) : Promise.resolve([]),
      ])
      if (requestId !== requestRef.current) return // a newer location/day was selected meanwhile
      setTasks(day)
      setOverdue(previous.filter(t => !t.completedAt))
      setError(null)
    } catch (err) {
      if (requestId !== requestRef.current) return
      setError(err instanceof Error ? err.message : 'Could not load tasks.')
    } finally {
      if (requestId === requestRef.current) setLoading(false)
    }
  }, [locationId, date, includeOverdue])

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setTasks([])
    setOverdue([])
    void reload()
  }, [reload])

  const patch = (id: string, change: Partial<TaskInstance>) => {
    const apply = (list: TaskInstance[]) => list.map(t => (t.id === id ? { ...t, ...change } : t))
    setTasks(apply)
    setOverdue(apply)
  }

  const run = useCallback(
    async (task: TaskInstance, optimistic: Partial<TaskInstance>, action: () => Promise<CompletionResult>) => {
      setPendingIds(ids => new Set(ids).add(task.id))
      patch(task.id, optimistic)
      try {
        const result = await action()
        patch(task.id, result)
        setError(null)
        return true
      } catch (err) {
        patch(task.id, {
          completedAt: task.completedAt,
          completedBy: task.completedBy,
          recordedValue: task.recordedValue,
          notes: task.notes,
        })
        setError(err instanceof Error ? err.message : 'Could not update the task.')
        // Someone else changed it: show the current state.
        if (err instanceof TaskApiError && err.code === 'TASK_STATE_CONFLICT') void reload()
        return false
      } finally {
        setPendingIds(ids => {
          const next = new Set(ids)
          next.delete(task.id)
          return next
        })
      }
    },
    [reload],
  )

  const complete = useCallback(
    (task: TaskInstance, input: CompleteInput = {}, userId?: string) =>
      run(
        task,
        { completedAt: new Date().toISOString(), completedBy: userId ?? null, recordedValue: input.recordedValue ?? null, notes: input.notes ?? null },
        () => taskInstancesApi.complete(task.id, input),
      ),
    [run],
  )

  const reopen = useCallback(
    (task: TaskInstance) =>
      run(task, { completedAt: null, completedBy: null, recordedValue: null, notes: null }, () => taskInstancesApi.reopen(task.id)),
    [run],
  )

  return { tasks, overdue, loading, error, clearError: () => setError(null), reload, complete, reopen, pendingIds }
}
