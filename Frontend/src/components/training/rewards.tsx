'use client'

import { useState } from 'react'
import { useReducedMotion } from '@/components/motion'
import { type Reward } from '@/lib/mock-data'

export function RewardCard({ reward, spendableXp, onRedeem }: { reward: Reward; spendableXp: number; onRedeem: (r: Reward) => void }) {
  const canAfford = spendableXp >= reward.cost
  const reduced = useReducedMotion()
  const progress = Math.min((spendableXp / reward.cost) * 100, 100)

  return (
    <div className={`bg-white rounded-xl border p-4 flex flex-col gap-3 transition-all duration-150 ${canAfford ? 'border-stone-200 hover:-translate-y-0.5 hover:shadow-md active:translate-y-0 active:shadow-sm' : 'border-stone-100'}`}
      style={{ opacity: canAfford ? 1 : 0.72 }}
    >
      <div className="flex items-start gap-3">
        <div className={`w-11 h-11 rounded-xl flex items-center justify-center text-2xl flex-shrink-0 ${canAfford ? 'bg-teal-50 border border-teal-100' : 'bg-stone-50 border border-stone-100'}`}>
          {reward.icon}
        </div>
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 flex-wrap">
            <p className="text-sm font-semibold text-stone-900 leading-snug">{reward.label}</p>
            {canAfford && (
              <span className="text-[10px] font-bold text-emerald-600 bg-emerald-50 border border-emerald-100 px-1.5 py-0.5 rounded-full">Unlocked</span>
            )}
          </div>
          <p className="text-xs text-stone-400 mt-0.5 leading-snug">{reward.desc}</p>
        </div>
      </div>

      {/* XP cost + progress */}
      <div>
        <div className="flex items-center justify-between mb-1.5">
          <span className="text-[10px] font-bold text-stone-400 uppercase tracking-widest">{reward.category}</span>
          <span className={`text-xs font-mono font-bold ${canAfford ? 'text-teal-700' : 'text-stone-400'}`}>
            {canAfford ? `${reward.cost.toLocaleString()} XP` : `${spendableXp.toLocaleString()} / ${reward.cost.toLocaleString()} XP`}
          </span>
        </div>
        {!canAfford && (
          <div className="w-full bg-stone-100 rounded-full h-1.5 overflow-hidden mb-2">
            <div
              className="h-1.5 rounded-full bg-stone-400"
              style={{
                width: `${reduced ? progress : 0}%`,
                transition: reduced ? 'none' : 'width 0.7s cubic-bezier(0.4,0,0.2,1) 0.1s',
              }}
              ref={el => {
                if (el && !reduced) requestAnimationFrame(() => { el.style.width = `${progress}%` })
              }}
            />
          </div>
        )}
        <button
          onClick={() => canAfford && onRedeem(reward)}
          disabled={!canAfford}
          className={`w-full py-2 rounded-lg text-xs font-semibold transition-all active:scale-[0.97]
            ${canAfford
              ? 'bg-teal-700 text-white hover:bg-teal-800'
              : 'bg-stone-100 text-stone-400 cursor-not-allowed'
            }`}
        >
          {canAfford ? `Redeem — ${reward.cost.toLocaleString()} XP` : `${(reward.cost - spendableXp).toLocaleString()} XP needed`}
        </button>
      </div>
    </div>
  )
}

export function RedeemModal({ reward, onConfirm, onCancel, spendableXp }: {
  reward: Reward; onConfirm: () => void; onCancel: () => void; spendableXp: number
}) {
  const reduced = useReducedMotion()
  return (
    <div className="fixed inset-0 z-50 flex items-end md:items-center justify-center p-4"
      style={{ backgroundColor: 'rgba(0,0,0,0.4)', backdropFilter: 'blur(2px)' }}
      onClick={onCancel}
    >
      <div
        className="bg-white rounded-2xl w-full max-w-sm p-6 shadow-2xl"
        onClick={e => e.stopPropagation()}
        style={{ animation: reduced ? 'none' : 'fadeScaleIn 0.25s cubic-bezier(0.34,1.56,0.64,1)' }}
      >
        <div className="text-center mb-5">
          <div className="text-5xl mb-3">{reward.icon}</div>
          <h2 className="text-lg font-bold text-stone-900">{reward.label}</h2>
          <p className="text-sm text-stone-500 mt-1">{reward.desc}</p>
        </div>
        <div className="bg-stone-50 rounded-xl p-4 mb-5 space-y-2">
          <div className="flex justify-between text-sm">
            <span className="text-stone-500">Your XP balance</span>
            <span className="font-mono font-bold text-stone-900">{spendableXp.toLocaleString()}</span>
          </div>
          <div className="flex justify-between text-sm">
            <span className="text-stone-500">Cost</span>
            <span className="font-mono font-bold text-red-600">−{reward.cost.toLocaleString()}</span>
          </div>
          <div className="border-t border-stone-200 pt-2 flex justify-between text-sm font-bold">
            <span className="text-stone-700">Remaining</span>
            <span className="font-mono text-teal-700">{(spendableXp - reward.cost).toLocaleString()}</span>
          </div>
        </div>
        <p className="text-xs text-stone-400 text-center mb-4">Show your manager the redemption code to claim this reward.</p>
        <div className="flex gap-3">
          <button onClick={onCancel} className="flex-1 py-2.5 rounded-xl text-sm font-semibold border border-stone-200 text-stone-700 hover:bg-stone-50 transition-all">
            Cancel
          </button>
          <button onClick={onConfirm} className="flex-1 py-2.5 rounded-xl text-sm font-semibold text-white bg-teal-700 hover:bg-teal-800 active:scale-[0.98] transition-all">
            Confirm Redeem
          </button>
        </div>
      </div>
    </div>
  )
}

export function RedemptionCode({ reward, code, xpLeft, onDone }: { reward: Reward; code: string; xpLeft: number; onDone: () => void }) {
  const reduced = useReducedMotion()
  const [copied, setCopied] = useState(false)

  function copy() {
    navigator.clipboard?.writeText(code).catch(() => {})
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  return (
    <div className="fixed inset-0 z-50 flex items-end md:items-center justify-center p-4"
      style={{ backgroundColor: 'rgba(0,0,0,0.4)', backdropFilter: 'blur(2px)' }}
    >
      <div
        className="bg-white rounded-2xl w-full max-w-sm p-6 shadow-2xl text-center"
        style={{ animation: reduced ? 'none' : 'fadeScaleIn 0.3s cubic-bezier(0.34,1.56,0.64,1)' }}
      >
        <div className="text-5xl mb-2" style={{ animation: reduced ? 'none' : 'bounceIn 0.5s ease 0.1s both' }}>🎉</div>
        <h2 className="text-lg font-bold text-stone-900 mb-1">Reward Redeemed!</h2>
        <p className="text-sm text-stone-500 mb-5">{reward.label}</p>

        {/* Code card */}
        <div className="bg-teal-50 border-2 border-dashed border-teal-300 rounded-xl px-5 py-4 mb-2">
          <p className="text-[10px] font-semibold text-teal-600 uppercase tracking-widest mb-1.5">Redemption Code</p>
          <p className="text-2xl font-mono font-bold text-teal-900 tracking-[0.2em]">{code}</p>
        </div>
        <button onClick={copy} className="text-xs font-semibold text-teal-700 hover:underline mb-5 block mx-auto">
          {copied ? '✓ Copied!' : 'Copy code'}
        </button>

        <div className="bg-stone-50 rounded-xl p-3 mb-5 text-sm flex items-center justify-between">
          <span className="text-stone-500">New XP balance</span>
          <span className="font-mono font-bold text-teal-700">{xpLeft.toLocaleString()} XP</span>
        </div>
        <p className="text-xs text-stone-400 mb-4">Show this code to your manager within 24 hours to claim your reward.</p>
        <button onClick={onDone} className="w-full py-2.5 rounded-xl text-sm font-semibold text-white bg-teal-700 hover:bg-teal-800 active:scale-[0.98] transition-all">
          Done
        </button>
      </div>
    </div>
  )
}
