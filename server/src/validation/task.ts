import {
  RECURRENCES,
  TASK_CATEGORIES,
  type CreateTaskInput,
  type UpdateTaskInput,
} from '../types/task.js'

// Lightweight hand-written validation (no extra dependency).
// Returns either the cleaned value or a list of human-readable errors.

export type ValidationResult<T> = { ok: true; value: T } | { ok: false; errors: string[] }

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/
const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/

type Body = Record<string, unknown>

function isPlainObject(v: unknown): v is Body {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

function checkField(key: string, value: unknown, errors: string[]): void {
  switch (key) {
    case 'label':
      if (typeof value !== 'string' || !value.trim()) errors.push('label must be a non-empty string')
      else if (value.length > 500) errors.push('label must be at most 500 characters')
      break
    case 'cat':
      if (!TASK_CATEGORIES.includes(value as never))
        errors.push(`cat must be one of: ${TASK_CATEGORIES.join(', ')}`)
      break
    case 'done':
      if (typeof value !== 'boolean') errors.push('done must be a boolean')
      break
    case 'date':
      if (typeof value !== 'string' || !DATE_RE.test(value) || Number.isNaN(Date.parse(value)))
        errors.push('date must be a valid date in YYYY-MM-DD format')
      break
    case 'time':
      if (typeof value !== 'string' || (value !== '' && !TIME_RE.test(value)))
        errors.push('time must be "" or HH:mm (24h)')
      break
    case 'attachments':
      if (!Array.isArray(value) || value.some(a => typeof a !== 'string'))
        errors.push('attachments must be an array of strings')
      break
    case 'recurrence':
      if (!RECURRENCES.includes(value as never))
        errors.push(`recurrence must be one of: ${RECURRENCES.join(', ')}`)
      break
    case 'recurrenceDays':
      if (
        !Array.isArray(value) ||
        value.some(d => !Number.isInteger(d) || (d as number) < 0 || (d as number) > 6)
      )
        errors.push('recurrenceDays must be an array of integers 0–6')
      break
  }
}

const EDITABLE_FIELDS = ['label', 'cat', 'done', 'date', 'time', 'attachments', 'recurrence', 'recurrenceDays'] as const

function pickEditable(body: Body): Body {
  const out: Body = {}
  for (const k of EDITABLE_FIELDS) if (k in body) out[k] = body[k]
  if (typeof out.label === 'string') out.label = out.label.trim()
  if (Array.isArray(out.recurrenceDays)) out.recurrenceDays = [...new Set(out.recurrenceDays as number[])].sort((a, b) => a - b)
  return out
}

export function validateCreate(body: unknown): ValidationResult<CreateTaskInput> {
  if (!isPlainObject(body)) return { ok: false, errors: ['request body must be a JSON object'] }
  const errors: string[] = []
  const data = pickEditable(body)

  for (const required of ['label', 'cat', 'date'] as const) {
    if (data[required] === undefined) errors.push(`${required} is required`)
  }
  // Defaults for optional fields
  data.time ??= ''
  data.attachments ??= []
  data.recurrence ??= 'none'
  data.recurrenceDays ??= []

  for (const [k, v] of Object.entries(data)) checkField(k, v, errors)
  if (errors.length) return { ok: false, errors }
  if (data.recurrence !== 'weekly') data.recurrenceDays = []
  return { ok: true, value: data as unknown as CreateTaskInput }
}

export function validateUpdate(body: unknown): ValidationResult<UpdateTaskInput> {
  if (!isPlainObject(body)) return { ok: false, errors: ['request body must be a JSON object'] }
  const errors: string[] = []
  const data = pickEditable(body)
  if (Object.keys(data).length === 0)
    return { ok: false, errors: [`provide at least one of: ${EDITABLE_FIELDS.join(', ')}`] }
  for (const [k, v] of Object.entries(data)) checkField(k, v, errors)
  if (errors.length) return { ok: false, errors }
  return { ok: true, value: data as UpdateTaskInput }
}
