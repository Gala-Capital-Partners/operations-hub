import { statusColor } from '@/lib/format'
import { SALES } from '@/lib/mock-data'

export function Ring({ pct, size = 48 }: { pct: number; size?: number }) {
  const stroke = size < 40 ? 3 : 4
  const r = (size - stroke * 2) / 2
  const circ = 2 * Math.PI * r
  const dash = (pct / 100) * circ
  return (
    <svg width={size} height={size} style={{ transform: 'rotate(-90deg)', flexShrink: 0 }}>
      <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke="#E7E5E4" strokeWidth={stroke} />
      <circle
        cx={size / 2} cy={size / 2} r={r} fill="none"
        stroke={statusColor(pct)} strokeWidth={stroke}
        strokeDasharray={`${dash} ${circ}`} strokeLinecap="round"
        style={{ transition: 'stroke-dasharray 0.4s ease' }}
      />
    </svg>
  )
}

export function SalesChart() {
  const max = Math.max(...SALES.flatMap(d => [d.today, d.yesterday]))
  const barH = 72
  const barW = 14
  const gap = 4
  const groupW = barW * 2 + gap + 10
  const w = SALES.length * groupW
  return (
    <div style={{ overflowX: 'auto' }}>
      <svg width={w} height={barH + 22}>
        {SALES.map((d, i) => {
          const x = i * groupW
          const h1 = (d.today / max) * barH
          const h2 = (d.yesterday / max) * barH
          return (
            <g key={d.day}>
              <rect x={x} y={barH - h2} width={barW} height={h2} rx={2} fill="#E7E5E4" />
              <rect x={x + barW + gap} y={barH - h1} width={barW} height={h1} rx={2} fill="#0F766E" />
              <text x={x + barW} y={barH + 15} textAnchor="middle" fill="#A8A29E" fontSize={10} style={{ fontFamily: 'var(--font-sans)' }}>{d.day}</text>
            </g>
          )
        })}
      </svg>
    </div>
  )
}
