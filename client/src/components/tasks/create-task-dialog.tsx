'use client'

import { useState, type FormEvent } from 'react'
import { taskDefinitionsApi, type TaskDefinitionInput } from '@/lib/api/task-definitions'

const CATEGORIES = ['Opening', 'Midday', 'Closing'] as const
const WEEKDAYS = [
  ['MO', 'Mon'], ['TU', 'Tue'], ['WE', 'Wed'], ['TH', 'Thu'], ['FR', 'Fri'], ['SA', 'Sat'], ['SU', 'Sun'],
] as const
type Weekday = (typeof WEEKDAYS)[number][0]
// Date#getUTCDay order (0 = Sunday)
const BY_UTC_DAY: Weekday[] = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA']

type Repeat = 'none' | 'daily' | 'weekly'

/** YYYY-MM-DD plus n days, using UTC as a neutral calendar. */
function addDays(date: string, n: number): string {
  const d = new Date(`${date}T00:00:00Z`)
  d.setUTCDate(d.getUTCDate() + n)
  return d.toISOString().slice(0, 10)
}

/**
 * The API requires a weekly task's start date to be one of its days, so start on
 * the first selected weekday on or after the chosen date.
 */
function firstWeeklyDate(start: string, days: Weekday[]): string {
  for (let i = 0; i < 7; i++) {
    const day = addDays(start, i)
    if (days.includes(BY_UTC_DAY[new Date(`${day}T00:00:00Z`).getUTCDay()])) return day
  }
  return start
}

function prettyDate(date: string) {
  return new Date(`${date}T00:00:00Z`).toLocaleDateString('en-US', { timeZone: 'UTC', weekday: 'short', month: 'short', day: 'numeric' })
}

const inputClass =
  'w-full border border-stone-200 rounded-lg px-3 py-2 text-sm text-stone-800 bg-white focus:outline-none focus:border-teal-600'
const labelClass = 'block text-xs font-semibold text-stone-500 uppercase tracking-wide mb-1.5'

/**
 * Create a task definition (POST /api/task-definitions). The backend validates and
 * authorizes everything again; these checks only give faster feedback.
 */
export function CreateTaskDialog({
  brand,
  location,
  canCreateBrandWide,
  today,
  onCreated,
  onClose,
}: {
  brand: { id: string; name: string }
  location: { id: string; name: string }
  /** The user may create tasks for every store in the brand (brand/organization admins) */
  canCreateBrandWide: boolean
  /** The store's local today, YYYY-MM-DD */
  today: string
  onCreated: (name: string) => void
  onClose: () => void
}) {
  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const [category, setCategory] = useState<(typeof CATEGORIES)[number]>('Opening')
  const [target, setTarget] = useState<'store' | 'brand'>('store')
  const [repeat, setRepeat] = useState<Repeat>('daily')
  const [days, setDays] = useState<Weekday[]>(['MO', 'WE', 'FR'])
  const [startDate, setStartDate] = useState(today)
  const [endDate, setEndDate] = useState('')
  const [timing, setTiming] = useState<'all_day' | 'timed'>('all_day')
  const [dueTime, setDueTime] = useState('')
  const [times, setTimes] = useState<string[]>(['10:00'])
  const [recordsValue, setRecordsValue] = useState(false)
  const [unit, setUnit] = useState('')
  const [min, setMin] = useState('')
  const [max, setMax] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)

  const orderedDays = WEEKDAYS.map(([code]) => code).filter(code => days.includes(code))
  const effectiveStart = repeat === 'weekly' && orderedDays.length > 0 ? firstWeeklyDate(startDate, orderedDays) : startDate

  function toggleDay(code: Weekday) {
    setDays(current => (current.includes(code) ? current.filter(d => d !== code) : [...current, code]))
  }

  function build(): TaskDefinitionInput | string {
    if (!name.trim()) return 'Give the task a name.'
    if ([...name.trim()].length > 200) return 'The name can be at most 200 characters.'
    if ([...description].length > 2000) return 'The instructions can be at most 2,000 characters.'
    if (!/^\d{4}-\d{2}-\d{2}$/.test(startDate)) return 'Choose a start date.'
    if (repeat === 'weekly' && orderedDays.length === 0) return 'Choose at least one day of the week.'
    if (repeat !== 'none' && endDate && endDate < effectiveStart) return 'The end date is before the first day.'

    const cleanTimes = [...new Set(times.filter(Boolean))].sort()
    if (timing === 'timed' && cleanTimes.length === 0) return 'Add at least one time.'

    let numericMin: number | null = null
    let numericMax: number | null = null
    if (recordsValue) {
      if (min.trim() !== '') numericMin = Number(min)
      if (max.trim() !== '') numericMax = Number(max)
      if ((numericMin !== null && !Number.isFinite(numericMin)) || (numericMax !== null && !Number.isFinite(numericMax))) {
        return 'Minimum and maximum must be numbers.'
      }
      if (numericMin !== null && numericMax !== null && numericMin > numericMax) return 'The minimum is above the maximum.'
      if ([...unit.trim()].length > 32) return 'The unit can be at most 32 characters.'
    }

    return {
      brandId: brand.id,
      locationId: target === 'brand' ? null : location.id,
      name: name.trim(),
      description: description.trim(),
      category,
      recurrenceRule: repeat === 'none' ? null : repeat === 'daily' ? 'FREQ=DAILY' : `FREQ=WEEKLY;BYDAY=${orderedDays.join(',')}`,
      startDate: effectiveStart,
      endDate: repeat !== 'none' && endDate ? endDate : null,
      scheduleMode: timing,
      scheduledTimes: timing === 'timed' ? cleanTimes : [],
      dueTime: timing === 'all_day' && dueTime ? dueTime : null,
      numericUnit: recordsValue && unit.trim() ? unit.trim() : null,
      numericMin,
      numericMax,
    }
  }

  async function submit(e: FormEvent) {
    e.preventDefault()
    const input = build()
    if (typeof input === 'string') return setError(input)
    setError(null)
    setSaving(true)
    try {
      await taskDefinitionsApi.create(input)
      onCreated(input.name)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not create the task.')
      setSaving(false)
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-end md:items-center justify-center p-4" role="dialog" aria-modal="true" aria-labelledby="create-task-title">
      <div className="absolute inset-0 bg-black/30" onClick={saving ? undefined : onClose} />
      <form
        onSubmit={submit}
        noValidate
        className="relative bg-white rounded-2xl shadow-xl w-full max-w-lg max-h-[90vh] overflow-y-auto p-6 space-y-5"
      >
        <div className="flex items-start justify-between gap-3">
          <div>
            <h2 id="create-task-title" className="text-lg font-semibold text-stone-900">New task</h2>
            <p className="text-xs text-stone-500 mt-0.5">{brand.name}</p>
          </div>
          <button type="button" onClick={onClose} disabled={saving} className="text-stone-400 hover:text-stone-600 text-xl leading-none" aria-label="Close">
            ×
          </button>
        </div>

        <div>
          <label htmlFor="task-name" className={labelClass}>Task</label>
          <input id="task-name" value={name} onChange={e => setName(e.target.value)} maxLength={200} placeholder="e.g. Log walk-in cooler temperature" className={inputClass} autoFocus />
        </div>

        <div>
          <label htmlFor="task-description" className={labelClass}>Instructions <span className="normal-case font-normal">(optional)</span></label>
          <textarea id="task-description" value={description} onChange={e => setDescription(e.target.value)} rows={2} maxLength={2000} className={inputClass} />
        </div>

        <div className="grid grid-cols-2 gap-3">
          <div>
            <label htmlFor="task-category" className={labelClass}>Shift</label>
            <select id="task-category" value={category} onChange={e => setCategory(e.target.value as (typeof CATEGORIES)[number])} className={inputClass}>
              {CATEGORIES.map(c => <option key={c}>{c}</option>)}
            </select>
          </div>
          <div>
            <label htmlFor="task-repeat" className={labelClass}>Repeats</label>
            <select id="task-repeat" value={repeat} onChange={e => setRepeat(e.target.value as Repeat)} className={inputClass}>
              <option value="none">Does not repeat</option>
              <option value="daily">Every day</option>
              <option value="weekly">Weekly on…</option>
            </select>
          </div>
        </div>

        {canCreateBrandWide && (
          <fieldset>
            <legend className={labelClass}>Applies to</legend>
            <div className="flex flex-col gap-1.5 text-sm text-stone-700">
              <label className="flex items-center gap-2"><input type="radio" checked={target === 'store'} onChange={() => setTarget('store')} /> This store ({location.name})</label>
              <label className="flex items-center gap-2"><input type="radio" checked={target === 'brand'} onChange={() => setTarget('brand')} /> Every store in {brand.name}</label>
            </div>
          </fieldset>
        )}

        {repeat === 'weekly' && (
          <fieldset>
            <legend className={labelClass}>Days</legend>
            <div className="flex flex-wrap gap-1.5">
              {WEEKDAYS.map(([code, label]) => (
                <button
                  key={code}
                  type="button"
                  aria-pressed={days.includes(code)}
                  onClick={() => toggleDay(code)}
                  className={`px-2.5 py-1 rounded-lg text-xs font-semibold border ${days.includes(code) ? 'bg-teal-700 border-teal-700 text-white' : 'border-stone-200 text-stone-600 hover:border-stone-300'}`}
                >
                  {label}
                </button>
              ))}
            </div>
          </fieldset>
        )}

        <div className="grid grid-cols-2 gap-3">
          <div>
            <label htmlFor="task-start" className={labelClass}>{repeat === 'none' ? 'Date' : 'Starts'}</label>
            <input id="task-start" type="date" value={startDate} onChange={e => setStartDate(e.target.value)} className={inputClass} />
            {repeat === 'weekly' && effectiveStart !== startDate && (
              <p className="text-[11px] text-stone-500 mt-1">First day: {prettyDate(effectiveStart)}</p>
            )}
          </div>
          {repeat !== 'none' && (
            <div>
              <label htmlFor="task-end" className={labelClass}>Ends <span className="normal-case font-normal">(optional)</span></label>
              <input id="task-end" type="date" value={endDate} min={effectiveStart} onChange={e => setEndDate(e.target.value)} className={inputClass} />
            </div>
          )}
        </div>

        <fieldset>
          <legend className={labelClass}>When</legend>
          <div className="flex flex-col gap-1.5 text-sm text-stone-700">
            <label className="flex items-center gap-2"><input type="radio" checked={timing === 'all_day'} onChange={() => setTiming('all_day')} /> Any time during the day</label>
            <label className="flex items-center gap-2"><input type="radio" checked={timing === 'timed'} onChange={() => setTiming('timed')} /> At specific times</label>
          </div>
          {timing === 'all_day' ? (
            <div className="mt-2 flex items-center gap-2">
              <label htmlFor="task-due" className="text-xs text-stone-500">Due by (optional)</label>
              <input id="task-due" type="time" value={dueTime} onChange={e => setDueTime(e.target.value)} className="border border-stone-200 rounded-lg px-2 py-1 text-sm" />
            </div>
          ) : (
            <div className="mt-2 space-y-1.5">
              {times.map((t, i) => (
                <div key={i} className="flex items-center gap-2">
                  <input
                    type="time"
                    aria-label={`Time ${i + 1}`}
                    value={t}
                    onChange={e => setTimes(list => list.map((v, j) => (j === i ? e.target.value : v)))}
                    className="border border-stone-200 rounded-lg px-2 py-1 text-sm"
                  />
                  {times.length > 1 && (
                    <button type="button" onClick={() => setTimes(list => list.filter((_, j) => j !== i))} className="text-xs text-stone-500 hover:text-red-600">
                      Remove
                    </button>
                  )}
                </div>
              ))}
              <button type="button" onClick={() => setTimes(list => [...list, ''])} className="text-xs font-semibold text-teal-700 hover:underline">
                + Add time
              </button>
            </div>
          )}
        </fieldset>

        <fieldset>
          <label className="flex items-center gap-2 text-sm text-stone-700">
            <input type="checkbox" checked={recordsValue} onChange={e => setRecordsValue(e.target.checked)} />
            Record a reading (e.g. a temperature)
          </label>
          {recordsValue && (
            <div className="mt-2 grid grid-cols-3 gap-2">
              <input aria-label="Unit" placeholder="Unit, e.g. °F" value={unit} onChange={e => setUnit(e.target.value)} maxLength={32} className={inputClass} />
              <input aria-label="Minimum" placeholder="Min" inputMode="decimal" value={min} onChange={e => setMin(e.target.value)} className={inputClass} />
              <input aria-label="Maximum" placeholder="Max" inputMode="decimal" value={max} onChange={e => setMax(e.target.value)} className={inputClass} />
            </div>
          )}
        </fieldset>

        {error && <p role="alert" className="text-sm text-red-700 bg-red-50 border border-red-200 rounded-xl px-3 py-2">{error}</p>}

        <div className="flex justify-end gap-2 pt-1">
          <button type="button" onClick={onClose} disabled={saving} className="px-4 py-2 rounded-xl text-sm font-semibold text-stone-600 hover:bg-stone-100">
            Cancel
          </button>
          <button type="submit" disabled={saving} className="px-4 py-2 rounded-xl text-sm font-semibold text-white bg-teal-700 hover:opacity-90 disabled:opacity-60 disabled:cursor-wait">
            {saving ? 'Creating…' : 'Create task'}
          </button>
        </div>
      </form>
    </div>
  )
}
