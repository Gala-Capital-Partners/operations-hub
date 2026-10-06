'use client'

import { useState } from 'react'
import { Confetti, SuccessToast, useReducedMotion } from '@/components/motion'
import { CHALLENGE } from '@/lib/mock-data'

export function TodaysChallenge() {
  const [tapped, setTapped] = useState<Set<number>>(new Set())
  const [submitted, setSubmitted] = useState(false)
  const [xpAwarded, setXpAwarded] = useState(0)
  const [showToast, setShowToast] = useState(false)
  const [confettiActive, setConfettiActive] = useState(false)
  const reduced = useReducedMotion()

  function toggle(id: number) {
    if (submitted) return
    setTapped(prev => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id); else next.add(id)
      return next
    })
  }

  function handleSubmit() {
    if (tapped.size === 0) return
    const violations = new Set(CHALLENGE.items.filter(i => i.violation).map(i => i.id))
    let correct = 0
    for (const id of tapped) { if (violations.has(id)) correct++ }
    for (const id of violations) { if (!tapped.has(id)) correct-- }
    const earned = Math.max(0, Math.round((correct / violations.size) * CHALLENGE.xp))
    setXpAwarded(earned)
    setSubmitted(true)
    if (earned > 0) {
      setConfettiActive(true)
      setShowToast(true)
      setTimeout(() => { setConfettiActive(false); setShowToast(false) }, 2800)
    }
  }

  function reset() {
    setTapped(new Set())
    setSubmitted(false)
    setXpAwarded(0)
    setConfettiActive(false)
    setShowToast(false)
  }

  return (
    <>
      <SuccessToast
        show={showToast}
        message={`+${xpAwarded} XP earned!`}
        sub="Challenge complete — nice work"
      />
      <div className="bg-white rounded-xl border border-stone-200 overflow-hidden">
        {/* Header */}
        <div className="px-5 pt-5 pb-4 border-b border-stone-100 flex items-center justify-between gap-3">
          <div className="flex items-center gap-3">
            <div className="w-9 h-9 rounded-xl bg-amber-50 border border-amber-100 flex items-center justify-center text-lg flex-shrink-0">⚡</div>
            <div>
              <div className="flex items-center gap-2">
                <p className="text-sm font-bold text-stone-900">{CHALLENGE.title}</p>
                <span className="text-[10px] font-bold text-amber-600 bg-amber-50 border border-amber-100 px-2 py-0.5 rounded-full">+{CHALLENGE.xp} XP</span>
              </div>
              <p className="text-[10px] text-stone-400 mt-0.5 uppercase tracking-widest font-semibold">Today&apos;s Challenge · ~2 min</p>
            </div>
          </div>
          {submitted && (
            <button onClick={reset} className="text-xs font-semibold text-teal-700 hover:underline flex-shrink-0">Retry</button>
          )}
        </div>

        {/* Scenario */}
        <div className="px-5 py-4">
          <p className="text-sm text-stone-600 leading-relaxed mb-4">{CHALLENGE.scenario}</p>
          <div className="space-y-2">
            {CHALLENGE.items.map((item, idx) => {
              const selected = tapped.has(item.id)
              const isViolation = item.violation
              let border = 'border-stone-200'
              let bg = 'bg-stone-50 hover:bg-stone-100'
              let icon = null
              if (submitted) {
                if (isViolation && selected) { border = 'border-emerald-400'; bg = 'bg-emerald-50'; icon = '✓' }
                else if (isViolation && !selected) { border = 'border-amber-400'; bg = 'bg-amber-50'; icon = '!' }
                else if (!isViolation && selected) { border = 'border-red-400'; bg = 'bg-red-50'; icon = '✗' }
                else { border = 'border-stone-200'; bg = 'bg-stone-50' }
              } else if (selected) {
                border = 'border-red-400'; bg = 'bg-red-50'
              }

              return (
                <button
                  key={item.id}
                  onClick={() => toggle(item.id)}
                  disabled={submitted}
                  className={`w-full text-left px-4 py-3 rounded-xl border-2 transition-all text-sm flex items-start gap-3 ${border} ${bg} ${submitted ? 'cursor-default' : 'active:scale-[0.99]'}`}
                  style={{
                    opacity: 0,
                    animation: reduced ? 'none' : `fadeSlideIn 0.3s ease forwards`,
                    animationDelay: reduced ? '0s' : `${idx * 55}ms`,
                  }}
                >
                  <span className={`w-5 h-5 rounded border-2 flex-shrink-0 flex items-center justify-center text-[10px] font-bold mt-0.5 transition-all
                    ${selected && !submitted ? 'bg-red-500 border-red-500 text-white' :
                      submitted && isViolation && selected ? 'bg-emerald-500 border-emerald-500 text-white' :
                      submitted && !isViolation && selected ? 'bg-red-400 border-red-400 text-white' :
                      'border-stone-300 text-stone-400'}`}
                  >
                    {submitted && icon ? icon : (selected && !submitted ? '!' : '')}
                  </span>
                  <div className="flex-1 min-w-0">
                    <span className={`${submitted && isViolation ? 'font-semibold text-stone-900' : 'text-stone-700'}`}>{item.text}</span>
                    {submitted && (
                      <p className={`text-xs mt-1 leading-snug ${isViolation ? 'text-red-700' : 'text-emerald-700'}`}>
                        {isViolation ? '⚠ ' : '✓ '}{item.explanation}
                      </p>
                    )}
                  </div>
                </button>
              )
            })}
          </div>

          {!submitted ? (
            <button
              onClick={handleSubmit}
              disabled={tapped.size === 0}
              className="w-full mt-4 py-2.5 rounded-xl text-sm font-semibold text-white bg-teal-700 disabled:opacity-40 disabled:cursor-not-allowed hover:bg-teal-800 active:scale-[0.98] transition-all"
            >
              Submit — I found the risks
            </button>
          ) : (
            <div className="relative mt-4 overflow-hidden">
              <Confetti active={confettiActive} />
              <div className={`p-4 rounded-xl border text-sm font-semibold flex items-center gap-3 ${xpAwarded >= CHALLENGE.xp * 0.7 ? 'bg-emerald-50 border-emerald-200 text-emerald-800' : 'bg-amber-50 border-amber-200 text-amber-800'}`}>
                <span className="text-2xl">{xpAwarded >= CHALLENGE.xp ? '🏆' : xpAwarded > 0 ? '🎯' : '📚'}</span>
                <div>
                  <p>{xpAwarded >= CHALLENGE.xp ? 'Perfect — all risks identified!' : xpAwarded > 0 ? 'Good eye — review the missed ones.' : 'Check the highlighted items above.'}</p>
                  <p className="text-xs font-mono mt-0.5 opacity-70">+{xpAwarded} / {CHALLENGE.xp} XP earned</p>
                </div>
              </div>
            </div>
          )}
        </div>
      </div>
    </>
  )
}
