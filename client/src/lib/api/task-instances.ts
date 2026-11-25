import { API_BASE_URL, ApiError } from '@/lib/api/tasks'
import { getAccessToken } from '@/lib/supabase'

/** A database task instance, as returned by GET /api/task-instances. */
export type TaskInstance = {
  id: string
  name: string
  description: string | null
  category: 'Opening' | 'Midday' | 'Closing'
  /** ISO UTC instant; for all-day tasks it is just the day's midnight anchor */
  scheduledAt: string
  /** The store's calendar day, YYYY-MM-DD */
  scheduledDay: string
  isAllDay: boolean
  timezone: string
  /** Local "HH:MM:SS" due time for all-day tasks, else null */
  dueTime: string | null
  completedAt: string | null
  completedBy: string | null
  recordedValue: number | null
  notes: string | null
  numericUnit: string | null
  numericMin: number | null
  numericMax: number | null
}

/** One store in GET /api/task-instances/summary. */
export type LocationTaskSummary = {
  locationId: string
  locationName: string
  storeNumber: string | null
  timezone: string
  brandId: string
  brandName: string
  total: number
  completed: number
  /** Open instances; not "overdue" (overdue rules are not decided yet) */
  remaining: number
}

/** Task counts for every store the user can read, for one calendar day. */
export type TaskSummary = {
  date: string
  totals: { locations: number; locationsWithoutTasks: number; total: number; completed: number; remaining: number }
  locations: LocationTaskSummary[]
}

export type CompletionResult = Pick<TaskInstance, 'id' | 'completedAt' | 'completedBy' | 'recordedValue' | 'notes'>

export type CompleteInput = { recordedValue?: number | null; notes?: string | null }

/** API error with the server's error code (e.g. TASK_STATE_CONFLICT). */
export class TaskApiError extends ApiError {
  constructor(message: string, status: number, public code?: string) {
    super(message, status)
    this.name = 'TaskApiError'
  }
}

const FRIENDLY: Record<string, string> = {
  TASK_OPERATION_FORBIDDEN: "You don't have permission to do that at this location.",
  TASK_STATE_CONFLICT: 'Someone else already changed this task. The list has been refreshed.',
  INVALID_TASK_INPUT: 'That reading is outside the allowed range.',
  TASK_DEFINITION_FORBIDDEN: "You can't create tasks for that store or brand.",
}

/** Authenticated JSON request to the backend; shared by the task API clients. */
export async function call<T>(path: string, init: RequestInit = {}): Promise<T> {
  const token = await getAccessToken()
  if (!token) throw new TaskApiError('Your session has ended. Please sign in again.', 401)

  let res: Response
  try {
    res = await fetch(`${API_BASE_URL}${path}`, {
      ...init,
      headers: { Authorization: `Bearer ${token}`, ...(init.body ? { 'Content-Type': 'application/json' } : {}), ...init.headers },
      cache: 'no-store',
    })
  } catch {
    throw new TaskApiError(`Cannot reach the API at ${API_BASE_URL}. Is the backend running?`, 0)
  }

  const body = await res.json().catch(() => null)
  if (!res.ok) {
    const code: string | undefined = body?.error?.code
    const message =
      res.status === 401
        ? 'Your session has ended. Please sign in again.'
        : (code && FRIENDLY[code]) ?? body?.error?.message ?? `Request failed (${res.status})`
    throw new TaskApiError(message, res.status, code)
  }
  return body as T
}

export const taskInstancesApi = {
  /** Tasks for one location on one store-local calendar day. */
  async list(locationId: string, date: string): Promise<TaskInstance[]> {
    const qs = new URLSearchParams({ locationId, date })
    const { tasks } = await call<{ tasks: TaskInstance[] }>(`/task-instances?${qs}`)
    return tasks
  },
  /** Per-store task counts for one calendar day, across every store the user can read. */
  summary(date: string): Promise<TaskSummary> {
    return call<TaskSummary>(`/task-instances/summary?${new URLSearchParams({ date })}`)
  },
  complete(id: string, input: CompleteInput = {}) {
    return call<CompletionResult>(`/task-instances/${encodeURIComponent(id)}/complete`, {
      method: 'POST',
      body: JSON.stringify(input),
    })
  },
  reopen(id: string) {
    return call<CompletionResult>(`/task-instances/${encodeURIComponent(id)}/reopen`, {
      method: 'POST',
      body: '{}',
    })
  },
}

/** Today's date (YYYY-MM-DD) in a store's timezone. */
export function localToday(timezone: string, now = new Date()): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(now)
}

/** Shift a YYYY-MM-DD date by whole days. */
export function addDays(date: string, days: number): string {
  const d = new Date(`${date}T00:00:00Z`)
  d.setUTCDate(d.getUTCDate() + days)
  return d.toISOString().slice(0, 10)
}

/** "11:00 AM" for a timed occurrence, shown in the store's timezone. */
export function localTimeOf(instance: Pick<TaskInstance, 'scheduledAt' | 'timezone'>): string {
  return new Intl.DateTimeFormat('en-US', { timeZone: instance.timezone, hour: 'numeric', minute: '2-digit' }).format(
    new Date(instance.scheduledAt),
  )
}
