'use client'

import { useCallback, useEffect, useRef, useState } from 'react'
import { tasksApi, type TaskQuery } from '@/lib/api/tasks'
import type { Task, TaskDraft } from '@/lib/types'

/**
 * Loads tasks from the backend and exposes CRUD actions.
 * Mutations are optimistic: the UI updates immediately and rolls back if the request fails.
 */
export function useTasks(query: TaskQuery = {}) {
  const [tasks, setTasks] = useState<Task[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const queryKey = JSON.stringify(query)
  const tasksRef = useRef<Task[]>(tasks)
  useEffect(() => {
    tasksRef.current = tasks
  }, [tasks])

  const reload = useCallback(async () => {
    setLoading(true)
    try {
      setTasks(await tasksApi.list(JSON.parse(queryKey) as TaskQuery))
      setError(null)
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setLoading(false)
    }
  }, [queryKey])

  useEffect(() => {
    // Initial fetch / refetch when the query changes
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void reload()
  }, [reload])

  /** Run an optimistic update; restore the previous list if the request fails. */
  const mutate = useCallback(async (optimistic: (prev: Task[]) => Task[], run: () => Promise<void>) => {
    const snapshot = tasksRef.current
    setTasks(optimistic)
    try {
      await run()
      setError(null)
    } catch (e) {
      setTasks(snapshot)
      setError((e as Error).message)
    }
  }, [])

  const createTask = useCallback(
    async (draft: TaskDraft) => {
      const tempId = -Date.now()
      await mutate(
        prev => [...prev, { id: tempId, done: false, ...draft }],
        async () => {
          const created = await tasksApi.create(draft)
          setTasks(prev => prev.map(t => (t.id === tempId ? created : t)))
        },
      )
    },
    [mutate],
  )

  const updateTask = useCallback(
    async (id: number, patch: Partial<Omit<Task, 'id'>>) => {
      await mutate(
        prev => prev.map(t => (t.id === id ? { ...t, ...patch } : t)),
        async () => {
          const saved = await tasksApi.update(id, patch)
          setTasks(prev => prev.map(t => (t.id === id ? saved : t)))
        },
      )
    },
    [mutate],
  )

  const toggleTask = useCallback(
    async (id: number) => {
      const current = tasksRef.current.find(t => t.id === id)
      if (current) await updateTask(id, { done: !current.done })
    },
    [updateTask],
  )

  const deleteTask = useCallback(
    async (id: number) => {
      await mutate(
        prev => prev.filter(t => t.id !== id),
        () => tasksApi.remove(id),
      )
    },
    [mutate],
  )

  return { tasks, loading, error, reload, createTask, updateTask, toggleTask, deleteTask, clearError: () => setError(null) }
}
