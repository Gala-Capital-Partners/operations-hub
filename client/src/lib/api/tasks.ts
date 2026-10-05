import type { Task, TaskDraft } from '@/lib/types'

// Base URL of the backend API. Override with NEXT_PUBLIC_API_URL in .env.local.
export const API_BASE_URL = (process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000/api').replace(/\/$/, '')

export class ApiError extends Error {
  constructor(
    message: string,
    public status: number,
    public details?: string[],
  ) {
    super(message)
    this.name = 'ApiError'
  }
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  let res: Response
  try {
    res = await fetch(`${API_BASE_URL}${path}`, {
      ...init,
      headers: { 'Content-Type': 'application/json', ...init?.headers },
      cache: 'no-store',
    })
  } catch {
    throw new ApiError(`Cannot reach the API at ${API_BASE_URL}. Is the backend running?`, 0)
  }

  if (res.status === 204) return undefined as T

  const body = await res.json().catch(() => null)
  if (!res.ok) {
    throw new ApiError(body?.error?.message ?? `Request failed (${res.status})`, res.status, body?.error?.details)
  }
  return body as T
}

export type TaskQuery = {
  date?: string
  from?: string
  to?: string
  cat?: Task['cat']
  done?: boolean
}

export const tasksApi = {
  list(query: TaskQuery = {}) {
    const params = new URLSearchParams()
    for (const [k, v] of Object.entries(query)) if (v !== undefined) params.set(k, String(v))
    const qs = params.toString()
    return request<Task[]>(`/tasks${qs ? `?${qs}` : ''}`)
  },
  get(id: number) {
    return request<Task>(`/tasks/${id}`)
  },
  create(draft: TaskDraft) {
    return request<Task>('/tasks', { method: 'POST', body: JSON.stringify(draft) })
  },
  update(id: number, patch: Partial<Omit<Task, 'id'>>) {
    return request<Task>(`/tasks/${id}`, { method: 'PATCH', body: JSON.stringify(patch) })
  },
  remove(id: number) {
    return request<void>(`/tasks/${id}`, { method: 'DELETE' })
  },
}
