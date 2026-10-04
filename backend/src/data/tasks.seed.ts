import type { Task } from '../types/task.js'

// Mock data copied from the original Figma Make export (src/App.tsx → TASKS_DATA).
// The demo is pinned to this date so "today" / "overdue" groupings stay stable.
export const DEMO_TODAY = '2026-08-19'
const TODAY = DEMO_TODAY

export const SEED_TASKS: Task[] = [
  { id: 1, label: 'Temperature log — walk-in cooler', cat: 'Opening', done: true, date: TODAY, time: '07:00', attachments: [], recurrence: 'daily', recurrenceDays: [] },
  { id: 2, label: 'Check sanitizer concentration at all stations', cat: 'Opening', done: true, date: TODAY, time: '07:30', attachments: [], recurrence: 'daily', recurrenceDays: [] },
  { id: 3, label: 'Review prep levels with kitchen lead', cat: 'Opening', done: false, date: TODAY, time: '08:00', attachments: [], recurrence: 'none', recurrenceDays: [] },
  { id: 4, label: 'Conduct line check before lunch service', cat: 'Midday', done: false, date: TODAY, time: '11:30', attachments: [], recurrence: 'daily', recurrenceDays: [] },
  { id: 5, label: 'Submit weekly order to distributor', cat: 'Midday', done: false, date: TODAY, time: '13:00', attachments: [], recurrence: 'weekly', recurrenceDays: [3] },
  { id: 6, label: 'Deposit preparation and safe count', cat: 'Closing', done: false, date: TODAY, time: '22:00', attachments: [], recurrence: 'none', recurrenceDays: [] },
  { id: 7, label: 'End-of-day cleaning checklist', cat: 'Closing', done: false, date: TODAY, time: '22:30', attachments: [], recurrence: 'daily', recurrenceDays: [] },
  { id: 8, label: 'Submit produce order for next week', cat: 'Midday', done: false, date: '2026-08-17', time: '', attachments: [], recurrence: 'none', recurrenceDays: [] },
  { id: 9, label: 'Log fridge temperatures — morning check', cat: 'Opening', done: false, date: '2026-08-16', time: '07:00', attachments: [], recurrence: 'none', recurrenceDays: [] },
]
