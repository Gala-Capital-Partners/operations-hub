'use client'

import { useState, useRef, type ChangeEvent } from 'react'
import { DAY_LABELS_CONST } from '@/lib/config'
import { formatTime } from '@/lib/format'
import { type Recurrence, TASK_CATS, type TaskCat, type TaskDraft, type TaskEntry } from '@/lib/types'

export function TaskModal({ initial, onSave, onDelete, onClose }: {
  initial?: TaskEntry
  onSave: (draft: TaskDraft) => void
  onDelete?: () => void
  onClose: () => void
}) {
  const isEdit = !!initial
  const [label, setLabel] = useState(initial?.label ?? '')
  const [cat, setCat] = useState<TaskCat>(initial?.cat as TaskCat ?? 'Opening')
  const [date, setDate] = useState(initial?.date ?? new Date().toISOString().slice(0, 10))
  const [time, setTime] = useState(initial?.time ?? '')
  const [showDatePicker, setShowDatePicker] = useState(false)
  const [showTimePicker, setShowTimePicker] = useState(false)
  const [calMonth, setCalMonth] = useState(() => {
    const d = new Date(initial?.date ?? new Date().toISOString().slice(0, 10))
    return new Date(d.getFullYear(), d.getMonth(), 1)
  })
  const [attachments, setAttachments] = useState<string[]>(initial?.attachments ?? [])
  const [attachInput, setAttachInput] = useState('')
  const [recurrence, setRecurrence] = useState<Recurrence>(initial?.recurrence ?? 'none')
  const [recurrenceDays, setRecurrenceDays] = useState<number[]>(initial?.recurrenceDays ?? [])
  const [showRepeatPicker, setShowRepeatPicker] = useState(false)
  const fileRef = useRef<HTMLInputElement>(null)

  const calDays = (() => {
    const year = calMonth.getFullYear()
    const month = calMonth.getMonth()
    const firstDow = new Date(year, month, 1).getDay()
    const daysInMonth = new Date(year, month + 1, 0).getDate()
    const cells: (number | null)[] = Array(firstDow).fill(null)
    for (let d = 1; d <= daysInMonth; d++) cells.push(d)
    while (cells.length % 7 !== 0) cells.push(null)
    return cells
  })()

  const timeHour = time ? (parseInt(time.split(':')[0]) % 12 || 12) : 12
  const timeMin = time ? parseInt(time.split(':')[1]) : 0
  const timeAmpm = time ? (parseInt(time.split(':')[0]) >= 12 ? 'PM' : 'AM') : 'AM'

  function selectDay(d: number) {
    const y = calMonth.getFullYear()
    const m = String(calMonth.getMonth() + 1).padStart(2, '0')
    const day = String(d).padStart(2, '0')
    setDate(`${y}-${m}-${day}`)
    setShowDatePicker(false)
  }

  function applyTime(h: number, min: number, ampm: string) {
    let hour24 = h % 12
    if (ampm === 'PM') hour24 += 12
    setTime(`${String(hour24).padStart(2, '0')}:${String(min).padStart(2, '0')}`)
  }

  function addAttachment() {
    const trimmed = attachInput.trim()
    if (trimmed) { setAttachments(p => [...p, trimmed]); setAttachInput('') }
  }

  function handleFile(e: ChangeEvent<HTMLInputElement>) {
    const files = Array.from(e.target.files ?? [])
    setAttachments(p => [...p, ...files.map(f => f.name)])
    e.target.value = ''
  }

  function toggleDay(d: number) {
    setRecurrenceDays(prev => prev.includes(d) ? prev.filter(x => x !== d) : [...prev, d].sort())
  }

  function handleSubmit() {
    if (!label.trim()) return
    onSave({ label: label.trim(), cat, date, time, attachments, recurrence, recurrenceDays: recurrence === 'weekly' ? recurrenceDays : [] })
    onClose()
  }

  return (
    <div
      className="fixed inset-0 z-50 flex items-end md:items-center justify-center p-4"
      style={{ backgroundColor: 'rgba(0,0,0,0.4)', backdropFilter: 'blur(2px)' }}
      onClick={onClose}
    >
      <div
        className="bg-white rounded-2xl w-full max-w-xl shadow-2xl overflow-hidden"
        onClick={e => e.stopPropagation()}
        style={{ animation: 'fadeScaleIn 0.22s cubic-bezier(0.34,1.4,0.64,1)' }}
      >
        {/* Header */}
        <div className="flex items-center justify-between px-6 py-5 border-b border-stone-100">
          <h2 className="text-sm font-bold text-stone-900">{isEdit ? 'Edit Task' : 'New Task'}</h2>
          <button onClick={onClose} className="w-11 h-11 -mr-2 -mt-2 flex items-center justify-center rounded-lg text-blue-600 hover:bg-blue-50 hover:text-blue-700 text-xl leading-none transition-colors" aria-label="Close edit task">×</button>
        </div>

        <div className="px-6 py-5 space-y-5 max-h-[75vh] overflow-y-auto">
          {/* Description */}
          <div>
            <label className="block text-xs font-semibold text-stone-500 uppercase tracking-wide mb-1.5">Task description</label>
            <textarea
              value={label}
              onChange={e => setLabel(e.target.value)}
              placeholder="e.g. Check sanitizer concentration at all stations"
              rows={3}
              className="w-full border border-stone-200 rounded-xl px-4 py-2.5 text-sm text-stone-900 placeholder:text-stone-400 focus:outline-none focus:border-teal-600 focus:ring-2 focus:ring-teal-600/20 transition-all resize-none bg-white"
              autoFocus
            />
          </div>

          {/* Date + Section row */}
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-xs font-semibold text-stone-500 uppercase tracking-wide mb-1.5">Date</label>
              <div className="border border-stone-200 rounded-xl bg-white">
                {/* Date row */}
                <div className="relative">
                  <div className="flex items-center gap-2 px-3 py-2.5 hover:bg-stone-50 rounded-t-xl transition-colors cursor-pointer" onClick={() => { setShowDatePicker(p => !p); setShowTimePicker(false); setShowRepeatPicker(false) }}>
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.75} strokeLinecap="round" strokeLinejoin="round" className="w-3.5 h-3.5 text-stone-400 flex-shrink-0">
                      <rect x="3" y="4" width="18" height="18" rx="2" ry="2"/><line x1="16" y1="2" x2="16" y2="6"/><line x1="8" y1="2" x2="8" y2="6"/><line x1="3" y1="10" x2="21" y2="10"/>
                    </svg>
                    <span className="flex-1 text-sm text-stone-900 select-none">
                      {date ? new Date(date + 'T00:00:00').toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' }) : 'Select date'}
                    </span>
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" className={`w-3.5 h-3.5 text-stone-300 flex-shrink-0 transition-transform ${showDatePicker ? 'rotate-180' : ''}`}>
                      <polyline points="6 9 12 15 18 9"/>
                    </svg>
                  </div>
                  {showDatePicker && (
                    <div className="absolute left-0 right-0 top-full z-20 mt-1 bg-white border border-stone-200 rounded-xl shadow-xl p-3" onClick={e => e.stopPropagation()}>
                      <div className="flex items-center justify-between mb-2">
                        <button type="button" onClick={() => setCalMonth(m => new Date(m.getFullYear(), m.getMonth() - 1, 1))} className="w-7 h-7 flex items-center justify-center rounded-lg hover:bg-stone-100 transition-colors text-stone-500">‹</button>
                        <span className="text-xs font-semibold text-stone-700">{calMonth.toLocaleDateString('en-US', { month: 'long', year: 'numeric' })}</span>
                        <button type="button" onClick={() => setCalMonth(m => new Date(m.getFullYear(), m.getMonth() + 1, 1))} className="w-7 h-7 flex items-center justify-center rounded-lg hover:bg-stone-100 transition-colors text-stone-500">›</button>
                      </div>
                      <div className="grid grid-cols-7 mb-1">
                        {['S','M','T','W','T','F','S'].map((d, i) => (
                          <div key={i} className="text-center text-[10px] font-semibold text-stone-400 py-1">{d}</div>
                        ))}
                      </div>
                      <div className="grid grid-cols-7 gap-y-0.5">
                        {calDays.map((d, i) => {
                          if (!d) return <div key={i} />
                          const cellDate = `${calMonth.getFullYear()}-${String(calMonth.getMonth() + 1).padStart(2, '0')}-${String(d).padStart(2, '0')}`
                          const isSelected = cellDate === date
                          return (
                            <button key={i} type="button" onClick={() => selectDay(d)} className={`w-full aspect-square rounded-lg text-xs font-medium transition-all ${isSelected ? 'bg-teal-700 text-white' : 'hover:bg-stone-100 text-stone-700'}`}>{d}</button>
                          )
                        })}
                      </div>
                    </div>
                  )}
                </div>

                {/* Time row */}
                <div className="border-t border-stone-100 relative">
                  <div className="flex items-center gap-2 px-3 py-2 hover:bg-stone-50 transition-colors cursor-pointer" onClick={() => { setShowTimePicker(p => !p); setShowDatePicker(false); setShowRepeatPicker(false) }}>
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.75} strokeLinecap="round" strokeLinejoin="round" className="w-3.5 h-3.5 text-stone-400 flex-shrink-0">
                      <circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>
                    </svg>
                    <span className={`flex-1 text-sm select-none ${time ? 'text-stone-900' : 'text-stone-400'}`}>
                      {time ? formatTime(time) : 'Add time'}
                    </span>
                    {time && (
                      <span role="button" onClick={e => { e.stopPropagation(); setTime(''); setShowTimePicker(false) }} className="text-stone-300 hover:text-stone-500 transition-colors text-base leading-none cursor-pointer">×</span>
                    )}
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" className={`w-3.5 h-3.5 text-stone-300 flex-shrink-0 transition-transform ${showTimePicker ? 'rotate-180' : ''}`}>
                      <polyline points="6 9 12 15 18 9"/>
                    </svg>
                  </div>
                  {showTimePicker && (
                    <div className="absolute left-0 right-0 top-full z-20 mt-1 bg-white border border-stone-200 rounded-xl shadow-xl p-3 space-y-3" onClick={e => e.stopPropagation()}>
                      <div className="flex items-center justify-center gap-2">
                        <div className="flex flex-col items-center gap-1">
                          <button type="button" onClick={() => applyTime(timeHour % 12 + 1, timeMin, timeAmpm)} className="w-7 h-7 flex items-center justify-center rounded-lg hover:bg-stone-100 transition-colors text-stone-500 text-sm">▲</button>
                          <span className="text-xl font-semibold text-stone-900 w-10 text-center tabular-nums">{String(timeHour).padStart(2, '0')}</span>
                          <button type="button" onClick={() => applyTime((timeHour - 2 + 12) % 12 + 1, timeMin, timeAmpm)} className="w-7 h-7 flex items-center justify-center rounded-lg hover:bg-stone-100 transition-colors text-stone-500 text-sm">▼</button>
                        </div>
                        <span className="text-xl font-semibold text-stone-400">:</span>
                        <div className="flex flex-col items-center gap-1">
                          <button type="button" onClick={() => applyTime(timeHour, (timeMin + 5) % 60, timeAmpm)} className="w-7 h-7 flex items-center justify-center rounded-lg hover:bg-stone-100 transition-colors text-stone-500 text-sm">▲</button>
                          <span className="text-xl font-semibold text-stone-900 w-10 text-center tabular-nums">{String(timeMin).padStart(2, '0')}</span>
                          <button type="button" onClick={() => applyTime(timeHour, (timeMin - 5 + 60) % 60, timeAmpm)} className="w-7 h-7 flex items-center justify-center rounded-lg hover:bg-stone-100 transition-colors text-stone-500 text-sm">▼</button>
                        </div>
                        <div className="flex flex-col gap-1 ml-1">
                          {['AM', 'PM'].map(a => (
                            <button key={a} type="button" onClick={() => applyTime(timeHour, timeMin, a)} className={`px-2.5 py-1 rounded-lg text-xs font-semibold border transition-all ${timeAmpm === a ? 'bg-teal-700 text-white border-teal-700' : 'bg-white text-stone-600 border-stone-200 hover:border-teal-300'}`}>{a}</button>
                          ))}
                        </div>
                      </div>
                      <button type="button" onClick={() => setShowTimePicker(false)} className="w-full py-2 rounded-lg text-xs font-semibold bg-teal-700 text-white hover:bg-teal-800 transition-colors">Done</button>
                    </div>
                  )}
                </div>
                <div className="border-t border-stone-100 relative">
                  <div className="flex items-center gap-2 px-3 py-2 hover:bg-stone-50 rounded-b-xl transition-colors cursor-pointer" onClick={() => { setShowRepeatPicker(p => !p); setShowDatePicker(false); setShowTimePicker(false) }}>
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.75} strokeLinecap="round" strokeLinejoin="round" className="w-3.5 h-3.5 text-stone-400 flex-shrink-0">
                      <polyline points="17 1 21 5 17 9"/><path d="M3 11V9a4 4 0 014-4h14"/><polyline points="7 23 3 19 7 15"/><path d="M21 13v2a4 4 0 01-4 4H3"/>
                    </svg>
                    <span className={`flex-1 text-sm select-none ${recurrence !== 'none' ? 'text-teal-700 font-semibold' : 'text-stone-700'}`}>
                      {recurrence === 'none' ? 'Repeat' : recurrence === 'daily' ? 'Daily' : `Weekly · ${recurrenceDays.map(d => DAY_LABELS_CONST[d]).join(', ') || 'no days'}`}
                    </span>
                    {recurrence !== 'none' && (
                      <span role="button" onClick={e => { e.stopPropagation(); setRecurrence('none'); setRecurrenceDays([]); setShowRepeatPicker(false) }} className="text-stone-300 hover:text-stone-500 transition-colors text-base leading-none cursor-pointer">×</span>
                    )}
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" className={`w-3.5 h-3.5 text-stone-300 flex-shrink-0 transition-transform ${showRepeatPicker ? 'rotate-180' : ''}`}>
                      <polyline points="6 9 12 15 18 9"/>
                    </svg>
                  </div>
                  {showRepeatPicker && (
                    <div className="absolute left-0 right-0 top-full z-20 mt-1 bg-white border border-stone-200 rounded-xl shadow-xl p-3 space-y-3" onClick={e => e.stopPropagation()}>
                      <div className="flex gap-2">
                        {(['none', 'daily', 'weekly'] as Recurrence[]).map(r => (
                          <button key={r} type="button" onClick={() => { setRecurrence(r); if (r !== 'weekly') { setRecurrenceDays([]); setShowRepeatPicker(false) } }} className={`flex-1 py-2 rounded-lg text-xs font-semibold transition-all border ${recurrence === r ? 'bg-teal-700 text-white border-teal-700' : 'bg-white text-stone-600 border-stone-200 hover:border-teal-300 hover:text-teal-700'}`}>
                            {r === 'none' ? 'None' : r === 'daily' ? 'Daily' : 'Weekly'}
                          </button>
                        ))}
                      </div>
                      {recurrence === 'weekly' && (
                        <>
                          <div className="flex gap-1.5 justify-between">
                            {DAY_LABELS_CONST.map((day, i) => (
                              <button key={i} type="button" onClick={() => toggleDay(i)} className={`flex-1 py-1.5 rounded-lg text-[11px] font-semibold transition-all border ${recurrenceDays.includes(i) ? 'bg-teal-700 text-white border-teal-700' : 'bg-white text-stone-500 border-stone-200 hover:border-teal-300 hover:text-teal-700'}`}>
                                {day[0]}
                              </button>
                            ))}
                          </div>
                          <button type="button" onClick={() => setShowRepeatPicker(false)} className="w-full py-2 rounded-lg text-xs font-semibold bg-teal-700 text-white hover:bg-teal-800 transition-colors">Done</button>
                        </>
                      )}
                    </div>
                  )}
                </div>
              </div>
            </div>
            <div>
              <label className="block text-xs font-semibold text-stone-500 uppercase tracking-wide mb-1.5">Section</label>
              <div className="flex flex-col gap-1.5">
                {TASK_CATS.map(c => (
                  <button
                    key={c}
                    type="button"
                    onClick={() => setCat(c)}
                    className={`px-3 py-1.5 rounded-lg text-xs font-semibold text-left transition-all border ${cat === c ? 'bg-teal-700 text-white border-teal-700' : 'bg-white text-stone-600 border-stone-200 hover:border-teal-300 hover:text-teal-700'}`}
                  >
                    {c}
                  </button>
                ))}
              </div>
            </div>
          </div>

          {/* Attachments */}
          <div>
            <label className="block text-xs font-semibold text-stone-500 uppercase tracking-wide mb-1.5">Attachments</label>
            <div className="flex gap-2 mb-2">
              <input
                type="text"
                value={attachInput}
                onChange={e => setAttachInput(e.target.value)}
                onKeyDown={e => e.key === 'Enter' && (e.preventDefault(), addAttachment())}
                placeholder="Paste a link or type a filename"
                className="flex-1 border border-stone-200 rounded-xl px-3 py-2 text-sm text-stone-900 placeholder:text-stone-400 focus:outline-none focus:border-teal-600 focus:ring-2 focus:ring-teal-600/20 transition-all bg-white"
              />
              <button type="button" onClick={addAttachment} className="px-3 py-2 rounded-xl text-xs font-semibold border border-stone-200 text-stone-600 hover:bg-stone-50 transition-colors flex-shrink-0">Add</button>
            </div>
            <button type="button" onClick={() => fileRef.current?.click()} className="flex items-center gap-2 text-xs font-semibold text-teal-700 hover:underline mb-2">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.75} strokeLinecap="round" strokeLinejoin="round" className="w-3.5 h-3.5">
                <path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" y1="3" x2="12" y2="15"/>
              </svg>
              Upload file from device
            </button>
            <input ref={fileRef} type="file" multiple className="hidden" onChange={handleFile} />
            {attachments.length > 0 && (
              <div className="space-y-1.5">
                {attachments.map((a, i) => (
                  <div key={i} className="flex items-center gap-2 bg-stone-50 border border-stone-100 rounded-lg px-3 py-1.5">
                    <span className="text-stone-400 flex-shrink-0">
                      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.75} strokeLinecap="round" strokeLinejoin="round" className="w-3.5 h-3.5">
                        <path d="M21.44 11.05l-9.19 9.19a6 6 0 01-8.49-8.49l9.19-9.19a4 4 0 015.66 5.66l-9.2 9.19a2 2 0 01-2.83-2.83l8.49-8.48"/>
                      </svg>
                    </span>
                    <span className="text-xs text-stone-600 flex-1 truncate">{a}</span>
                    <button onClick={() => setAttachments(p => p.filter((_, j) => j !== i))} className="text-stone-300 hover:text-red-400 transition-colors flex-shrink-0 text-base leading-none">×</button>
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>

        {/* Footer */}
        <div className="px-6 py-5 border-t border-stone-100 bg-stone-50 space-y-2">
          <div className="flex gap-3">
            <button onClick={onClose} className="flex-1 py-2.5 rounded-xl text-sm font-semibold border border-stone-200 text-stone-700 hover:bg-stone-100 transition-all">
              Cancel
            </button>
            <button
              onClick={handleSubmit}
              disabled={!label.trim()}
              className="flex-1 py-2.5 rounded-xl text-sm font-semibold text-white bg-teal-700 hover:bg-teal-800 disabled:opacity-40 disabled:cursor-not-allowed active:scale-[0.98] transition-all"
            >
              {isEdit ? 'Save Changes' : 'Add Task'}
            </button>
          </div>
          {isEdit && onDelete && (
            <button
              onClick={() => { onDelete(); onClose() }}
              className="w-full py-2 rounded-xl text-sm font-semibold text-red-600 hover:bg-red-50 border border-transparent hover:border-red-100 active:scale-[0.98] transition-all"
            >
              Delete Task
            </button>
          )}
        </div>
      </div>
    </div>
  )
}
