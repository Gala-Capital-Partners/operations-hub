'use client'

import { useState, useEffect } from 'react'
import { useReducedMotion } from '@/components/motion'

export function XPBar({ current, max, animate = false, delay = 0 }: { current: number; max: number; animate?: boolean; delay?: number }) {
  const pct = Math.min((current / max) * 100, 100)
  const reduced = useReducedMotion()
  const [displayed, setDisplayed] = useState((animate && !reduced) ? 0 : pct)
  useEffect(() => {
    if (!animate || reduced) { setDisplayed(pct); return }
    const id = setTimeout(() => setDisplayed(pct), delay)
    return () => clearTimeout(id)
  }, [pct, animate, delay, reduced])
  return (
    <div className="w-full bg-stone-100 rounded-full h-2 overflow-hidden">
      <div
        className="h-2 rounded-full"
        style={{
          width: `${displayed}%`,
          background: 'linear-gradient(90deg, #0F766E, #14B8A6)',
          transition: (animate && !reduced) ? 'width 0.9s cubic-bezier(0.4,0,0.2,1)' : 'none',
        }}
      />
    </div>
  )
}

export function QuizTimer({ seconds, onExpire }: { seconds: number; onExpire: () => void }) {
  const [timeLeft, setTimeLeft] = useState(seconds)
  const reduced = useReducedMotion()
  const pct = (timeLeft / seconds) * 100
  const color = timeLeft <= 5 ? '#DC2626' : timeLeft <= 10 ? '#D97706' : '#0F766E'
  const circ = 94.25

  useEffect(() => {
    const id = setInterval(() => {
      setTimeLeft(t => {
        if (t <= 1) { clearInterval(id); onExpire(); return 0 }
        return t - 1
      })
    }, 1000)
    return () => clearInterval(id)
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return (
    <div className="flex items-center gap-2">
      <svg width={36} height={36} style={{ transform: 'rotate(-90deg)', flexShrink: 0 }}>
        <circle cx={18} cy={18} r={15} fill="none" stroke="#E7E5E4" strokeWidth={3} />
        <circle
          cx={18} cy={18} r={15} fill="none"
          stroke={color} strokeWidth={3}
          strokeDasharray={`${(pct / 100) * circ} ${circ}`}
          strokeLinecap="round"
          style={{ transition: reduced ? 'none' : 'stroke-dasharray 0.9s linear, stroke 0.3s' }}
        />
      </svg>
      <span className="font-mono text-sm font-bold tabular-nums" style={{ color }}>{timeLeft}s</span>
    </div>
  )
}
