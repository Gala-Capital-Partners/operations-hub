'use client'

import { useState, useEffect, useRef, useSyncExternalStore } from 'react'
import { statusColor } from '@/lib/format'

const REDUCED_MOTION_QUERY = '(prefers-reduced-motion: reduce)'

function subscribeReducedMotion(onChange: () => void) {
  const mq = window.matchMedia(REDUCED_MOTION_QUERY)
  mq.addEventListener('change', onChange)
  return () => mq.removeEventListener('change', onChange)
}

// SSR-safe: renders "false" on the server, then reads the real media query on the client.
export function useReducedMotion() {
  return useSyncExternalStore(
    subscribeReducedMotion,
    () => window.matchMedia(REDUCED_MOTION_QUERY).matches,
    () => false,
  )
}

export function useCountUp(target: number, duration = 800, enabled = true) {
  const [value, setValue] = useState(enabled ? 0 : target)
  useEffect(() => {
    if (!enabled) { setValue(target); return }
    let start: number | null = null
    const step = (ts: number) => {
      if (!start) start = ts
      const progress = Math.min((ts - start) / duration, 1)
      setValue(Math.round(progress * target))
      if (progress < 1) requestAnimationFrame(step)
    }
    const id = requestAnimationFrame(step)
    return () => cancelAnimationFrame(id)
  }, [target, duration, enabled])
  return value
}

// Animated ring: mounts at 0 then transitions to target pct
export function AnimatedRing({ pct, size = 48, delay = 0 }: { pct: number; size?: number; delay?: number }) {
  const reduced = useReducedMotion()
  const [displayed, setDisplayed] = useState(reduced ? pct : 0)
  const stroke = size < 40 ? 3 : 4
  const r = (size - stroke * 2) / 2
  const circ = 2 * Math.PI * r
  const dash = (displayed / 100) * circ

  useEffect(() => {
    if (reduced) return
    const id = setTimeout(() => setDisplayed(pct), delay)
    return () => clearTimeout(id)
  }, [pct, delay, reduced])

  return (
    <svg width={size} height={size} style={{ transform: 'rotate(-90deg)', flexShrink: 0 }}>
      <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke="#E7E5E4" strokeWidth={stroke} />
      <circle
        cx={size / 2} cy={size / 2} r={r} fill="none"
        stroke={statusColor(displayed)} strokeWidth={stroke}
        strokeDasharray={`${dash} ${circ}`} strokeLinecap="round"
        style={{ transition: reduced ? 'none' : 'stroke-dasharray 0.7s cubic-bezier(0.4,0,0.2,1)' }}
      />
    </svg>
  )
}

// Animated progress bar: mounts at 0 then grows to target
export function AnimatedBar({ pct, color, delay = 0, h = 'h-1.5' }: { pct: number; color: string; delay?: number; h?: string }) {
  const reduced = useReducedMotion()
  const [displayed, setDisplayed] = useState(reduced ? pct : 0)
  useEffect(() => {
    if (reduced) { setDisplayed(pct); return }
    const id = setTimeout(() => setDisplayed(pct), delay)
    return () => clearTimeout(id)
  }, [pct, delay, reduced])
  return (
    <div className={`${h} rounded-full`} style={{
      width: `${displayed}%`,
      backgroundColor: color,
      transition: reduced ? 'none' : 'width 0.7s cubic-bezier(0.4,0,0.2,1)',
    }} />
  )
}

// Lightweight canvas confetti burst
export function Confetti({ active }: { active: boolean }) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const reduced = useReducedMotion()

  useEffect(() => {
    if (!active || reduced) return
    const canvas = canvasRef.current
    if (!canvas) return
    const ctx = canvas.getContext('2d')
    if (!ctx) return

    canvas.width = canvas.offsetWidth
    canvas.height = canvas.offsetHeight

    const COLORS = ['#0F766E', '#14B8A6', '#F59E0B', '#10B981', '#6366F1', '#EA5A0C']
    const particles = Array.from({ length: 52 }, (_, i) => ({
      x: canvas.width / 2 + (Math.random() - 0.5) * 60,
      y: canvas.height * 0.35,
      vx: (Math.random() - 0.5) * 9,
      vy: -Math.random() * 8 - 3,
      color: COLORS[i % COLORS.length],
      size: Math.random() * 6 + 4,
      rotation: Math.random() * Math.PI * 2,
      rotV: (Math.random() - 0.5) * 0.3,
      alpha: 1,
    }))

    let rafId: number
    const draw = () => {
      ctx.clearRect(0, 0, canvas.width, canvas.height)
      let alive = false
      for (const p of particles) {
        p.x += p.vx
        p.y += p.vy
        p.vy += 0.28
        p.vx *= 0.99
        p.rotation += p.rotV
        p.alpha -= 0.013
        if (p.alpha <= 0) continue
        alive = true
        ctx.save()
        ctx.globalAlpha = p.alpha
        ctx.fillStyle = p.color
        ctx.translate(p.x, p.y)
        ctx.rotate(p.rotation)
        ctx.fillRect(-p.size / 2, -p.size / 4, p.size, p.size / 2)
        ctx.restore()
      }
      if (alive) rafId = requestAnimationFrame(draw)
      else ctx.clearRect(0, 0, canvas.width, canvas.height)
    }
    rafId = requestAnimationFrame(draw)
    return () => cancelAnimationFrame(rafId)
  }, [active, reduced])

  return (
    <canvas
      ref={canvasRef}
      className="pointer-events-none absolute inset-0 w-full h-full"
      style={{ zIndex: 10 }}
    />
  )
}

// Slide-in success toast
export function SuccessToast({ show, message, sub }: { show: boolean; message: string; sub?: string }) {
  const reduced = useReducedMotion()
  return (
    <div
      className="fixed top-4 left-1/2 z-50 pointer-events-none"
      style={{
        transform: `translateX(-50%) translateY(${show ? '0' : '-80px'})`,
        opacity: show ? 1 : 0,
        transition: reduced ? 'none' : 'transform 0.35s cubic-bezier(0.34,1.56,0.64,1), opacity 0.25s ease',
      }}
    >
      <div className="bg-stone-900 text-white text-sm font-semibold px-5 py-3 rounded-2xl shadow-xl flex items-center gap-3 whitespace-nowrap">
        <span className="text-lg">🎉</span>
        <div>
          <p>{message}</p>
          {sub && <p className="text-xs text-stone-400 font-normal mt-0.5">{sub}</p>}
        </div>
      </div>
    </div>
  )
}
