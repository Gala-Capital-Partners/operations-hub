// Task model — mirrors the fields used by the Figma design (TasksScreen / TaskModal).

export const TASK_CATEGORIES = ['Opening', 'Midday', 'Closing'] as const
export type TaskCategory = (typeof TASK_CATEGORIES)[number]

export const RECURRENCES = ['none', 'daily', 'weekly'] as const
export type Recurrence = (typeof RECURRENCES)[number]

export interface Task {
  id: number
  /** Task description shown in the list */
  label: string
  /** Shift section: Opening / Midday / Closing */
  cat: TaskCategory
  done: boolean
  /** Due date, YYYY-MM-DD */
  date: string
  /** Due time, HH:mm (24h) or "" when not set */
  time: string
  /** File names or links */
  attachments: string[]
  recurrence: Recurrence
  /** Weekday indices (0 = Sun … 6 = Sat), only used when recurrence = "weekly" */
  recurrenceDays: number[]
}

/** Body accepted by POST /api/tasks */
export type CreateTaskInput = Omit<Task, 'id' | 'done'> & { done?: boolean }

/** Body accepted by PATCH /api/tasks/:id */
export type UpdateTaskInput = Partial<Omit<Task, 'id'>>
