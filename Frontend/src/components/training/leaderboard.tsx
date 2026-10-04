'use client'

import { useState, useEffect } from 'react'
import { useCountUp } from '@/components/motion'
import { type LeaderboardEntry } from '@/lib/mock-data'

export function PodiumBar({ p, podiumIdx, reduced }: { p: LeaderboardEntry; podiumIdx: number; reduced: boolean }) {
  const targetH = [80, 112, 64][podiumIdx]
  const [h, setH] = useState(reduced ? targetH : 4)
  useEffect(() => {
    if (reduced) { setH(targetH); return }
    const id = setTimeout(() => setH(targetH), podiumIdx * 80 + 50)
    return () => clearTimeout(id)
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])
  const labels = ['2nd', '1st', '3rd']
  const colors = ['#D6D3D1', '#0F766E', '#A8A29E']
  const textColors = ['text-stone-600', 'text-white', 'text-stone-600']
  return (
    <div className="flex flex-col items-center flex-1 max-w-[100px]">
      <div className={`w-10 h-10 rounded-full flex items-center justify-center text-sm font-bold mb-1.5 bg-stone-100 text-stone-700 ${p.isMe ? 'ring-2 ring-teal-500 ring-offset-2' : ''}`}>
        {p.initials}
      </div>
      <p className="text-[10px] font-semibold text-stone-700 text-center mb-1 leading-tight">{p.name.split(' ')[0]}</p>
      <div
        className="w-full rounded-t-lg flex items-end justify-center pb-2 overflow-hidden"
        style={{ height: h, backgroundColor: colors[podiumIdx], transition: reduced ? 'none' : 'height 0.55s cubic-bezier(0.34,1.2,0.64,1)' }}
      >
        <span className={`text-sm font-bold ${textColors[podiumIdx]}`}>{labels[podiumIdx]}</span>
      </div>
    </div>
  )
}

export function LeaderboardRow({ p, rowIdx, reduced }: { p: LeaderboardEntry; rowIdx: number; reduced: boolean }) {
  const countedXp = useCountUp(p.xp, 900, !reduced)
  return (
    <div
      className={`px-5 py-3.5 grid gap-3 items-center transition-colors ${p.isMe ? 'bg-teal-50 border-l-2 border-teal-600' : 'hover:bg-stone-50'}`}
      style={{
        gridTemplateColumns: '32px 1fr 64px 72px',
        opacity: 0,
        animation: reduced ? 'none' : `fadeSlideIn 0.3s ease forwards`,
        animationDelay: reduced ? '0s' : `${rowIdx * 55 + 120}ms`,
      }}
    >
      <span className="text-sm font-mono font-bold text-stone-400">{p.badge ?? `#${p.rank}`}</span>
      <div className="min-w-0">
        <p className={`text-sm font-semibold truncate ${p.isMe ? 'text-teal-800' : 'text-stone-800'}`}>
          {p.name}{p.isMe && <span className="text-[10px] font-bold text-teal-600 ml-1.5">you</span>}
        </p>
        <p className="text-[10px] text-stone-400">Level {p.level}</p>
      </div>
      <p className="text-xs font-mono text-right text-amber-600">{p.streak > 0 ? `🔥 ${p.streak}d` : '—'}</p>
      <p className={`text-sm font-mono font-bold text-right tabular-nums ${p.isMe ? 'text-teal-700' : 'text-stone-700'}`}>
        {countedXp.toLocaleString()}
      </p>
    </div>
  )
}
