import { call } from '@/lib/api/task-instances'

/** Body of POST /api/task-definitions (see server/README.md, "Create a task definition"). */
export type TaskDefinitionInput = {
  brandId: string
  /** null = every active store in the brand (brand-wide) */
  locationId: string | null
  name: string
  description: string
  category: 'Opening' | 'Midday' | 'Closing'
  /** null = one-time task on startDate */
  recurrenceRule: string | null
  /** YYYY-MM-DD; for a repeating task it must be the first matching day */
  startDate: string
  endDate: string | null
  scheduleMode: 'all_day' | 'timed'
  /** HH:mm local times; required for timed tasks, empty for all-day */
  scheduledTimes: string[]
  /** HH:mm; all-day tasks only */
  dueTime: string | null
  numericUnit: string | null
  numericMin: number | null
  numericMax: number | null
}

export type TaskDefinition = TaskDefinitionInput & {
  id: string
  createdBy: string
  isActive: boolean
  createdAt: string
  updatedAt: string
}

export const taskDefinitionsApi = {
  /** Saves the definition and generates its first week of tasks in one transaction. */
  create(input: TaskDefinitionInput) {
    return call<TaskDefinition>('/task-definitions', { method: 'POST', body: JSON.stringify(input) })
  },
}
