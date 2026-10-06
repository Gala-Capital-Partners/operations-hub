import { SEED_TASKS } from '../data/tasks.seed.js'
import type { CreateTaskInput, Task, UpdateTaskInput } from '../types/task.js'

/**
 * In-memory task repository.
 *
 * Data lives only for the lifetime of the process (restarting the server resets it
 * to the seed data). When a database is added later, replace this module with one
 * that has the same function signatures — the routes don't need to change.
 */

let tasks: Task[] = structuredClone(SEED_TASKS)
let nextId = Math.max(0, ...tasks.map(t => t.id)) + 1

export interface TaskFilter {
  date?: string
  from?: string
  to?: string
  cat?: Task['cat']
  done?: boolean
}

export function listTasks(filter: TaskFilter = {}): Task[] {
  return tasks
    .filter(t => (filter.date ? t.date === filter.date : true))
    .filter(t => (filter.from ? t.date >= filter.from : true))
    .filter(t => (filter.to ? t.date <= filter.to : true))
    .filter(t => (filter.cat ? t.cat === filter.cat : true))
    .filter(t => (filter.done !== undefined ? t.done === filter.done : true))
    .sort((a, b) => a.date.localeCompare(b.date) || a.time.localeCompare(b.time) || a.id - b.id)
}

export function getTask(id: number): Task | undefined {
  return tasks.find(t => t.id === id)
}

export function createTask(input: CreateTaskInput): Task {
  const task: Task = { id: nextId++, ...input, done: input.done ?? false }
  tasks.push(task)
  return task
}

export function updateTask(id: number, patch: UpdateTaskInput): Task | undefined {
  const idx = tasks.findIndex(t => t.id === id)
  if (idx === -1) return undefined
  const updated: Task = { ...tasks[idx], ...patch, id }
  // Weekly days only make sense for weekly recurrence
  if (updated.recurrence !== 'weekly') updated.recurrenceDays = []
  tasks[idx] = updated
  return updated
}

export function deleteTask(id: number): boolean {
  const before = tasks.length
  tasks = tasks.filter(t => t.id !== id)
  return tasks.length < before
}

/** Restore the original mock data (handy during demos / tests). */
export function resetTasks(): void {
  tasks = structuredClone(SEED_TASKS)
  nextId = Math.max(0, ...tasks.map(t => t.id)) + 1
}
