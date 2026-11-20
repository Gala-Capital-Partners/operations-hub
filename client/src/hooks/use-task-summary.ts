'use client'

import { useCallback, useEffect, useRef, useState } from 'react'
import { taskInstancesApi, type TaskSummary } from '@/lib/api/task-instances'

/** Per-store task counts for one calendar day (manager rollup). */
export function useTaskSummary(date: string) {
  const [summary, setSummary] = useState<TaskSummary | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const requestRef = useRef(0)

  const reload = useCallback(async () => {
    const requestId = ++requestRef.current
    setLoading(true)
    try {
      const next = await taskInstancesApi.summary(date)
      if (requestId !== requestRef.current) return // a newer request replaced this one
      setSummary(next)
      setError(null)
    } catch (err) {
      if (requestId !== requestRef.current) return
      setError(err instanceof Error ? err.message : 'Could not load the task summary.')
    } finally {
      if (requestId === requestRef.current) setLoading(false)
    }
  }, [date])

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void reload()
  }, [reload])

  return { summary, loading, error, reload }
}
