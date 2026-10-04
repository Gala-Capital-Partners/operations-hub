export type Role = 'corporate' | 'brand' | 'manager' | 'employee'
export type Brand = 'burgercraft' | 'tacoverde'
export type Screen = 'login' | 'dashboard' | 'knowledge' | 'tasks' | 'training' | 'compliance'
export type NavItem = { id: Screen; label: string; roles: Role[] }
export type Recurrence = 'none' | 'daily' | 'weekly'

export const TASK_CATS = ['Opening', 'Midday', 'Closing'] as const
export type TaskCat = (typeof TASK_CATS)[number]
export type TaskDraft = { label: string; cat: TaskCat; date: string; time: string; attachments: string[]; recurrence: Recurrence; recurrenceDays: number[] }
/** A task as returned by the Tasks API */
export type Task = TaskDraft & { id: number; done: boolean }
/** Kept for compatibility with the original component names */
export type TaskEntry = Task
