export function statusColor(pct: number): string {
  if (pct >= 100) return '#16A34A'
  if (pct >= 60) return '#0F766E'
  if (pct >= 30) return '#D97706'
  return '#DC2626'
}

export function expiryBadge(daysLeft: number) {
  if (daysLeft <= 7)
    return { label: `${daysLeft}d — Urgent`, cls: 'bg-red-50 text-red-700 border-red-200', dot: 'bg-red-500', alertIcon: true }
  if (daysLeft <= 30)
    return { label: `${daysLeft}d — Critical`, cls: 'bg-red-50 text-red-700 border-red-200', dot: 'bg-red-400', alertIcon: true }
  if (daysLeft <= 90)
    return { label: `${daysLeft}d — Watch`, cls: 'bg-amber-50 text-amber-700 border-amber-200', dot: 'bg-amber-400', alertIcon: false }
  return { label: `${Math.round(daysLeft / 30)}mo`, cls: 'bg-stone-50 text-stone-500 border-stone-200', dot: 'bg-emerald-400', alertIcon: false }
}

export function formatTime(t: string) {
  if (!t) return ''
  const [h, m] = t.split(':').map(Number)
  const ampm = h >= 12 ? 'PM' : 'AM'
  const hour = h % 12 || 12
  return `${hour}:${String(m).padStart(2, '0')} ${ampm}`
}
