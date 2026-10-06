'use client'

import { useState } from 'react'
import { Ic } from '@/components/icons'
import { BRANDS } from '@/lib/config'
import { expiryBadge } from '@/lib/format'
import { DOCS } from '@/lib/mock-data'

export function ComplianceScreen() {
  const [typeFilter, setTypeFilter] = useState('All')
  const [brandFilter, setBrandFilter] = useState('All')
  const [sortBy, setSortBy] = useState<'expiry' | 'name'>('expiry')

  const docTypes = ['All', 'Franchise Agreement', 'Lease', 'Amendment', 'Renewal']

  const filtered = DOCS
    .filter(d => typeFilter === 'All' || d.type === typeFilter)
    .filter(d => brandFilter === 'All' || d.brand === brandFilter)
    .sort((a, b) => sortBy === 'expiry' ? a.daysLeft - b.daysLeft : a.name.localeCompare(b.name))

  const criticalCount = DOCS.filter(d => d.daysLeft <= 30).length

  return (
    <div className="p-4 md:p-6 max-w-5xl mx-auto space-y-4">
      <div className="flex items-start justify-between gap-3">
        <div>
          <div className="flex items-center gap-2.5 flex-wrap">
            <h1 className="text-xl font-semibold text-stone-900">Compliance</h1>
            {criticalCount > 0 && (
              <span className="text-xs bg-red-50 text-red-700 border border-red-200 px-2 py-0.5 rounded-full font-semibold">
                {criticalCount} expiring soon
              </span>
            )}
          </div>
          <p className="text-xs text-stone-500 mt-0.5">Franchise agreements, leases, and amendments</p>
        </div>
        <button className="text-xs font-semibold text-teal-700 border border-teal-200 bg-teal-50 hover:bg-teal-100 px-3.5 py-2 rounded-lg transition-colors flex-shrink-0">
          + Upload
        </button>
      </div>

      {/* Critical alert banner */}
      {DOCS.some(d => d.daysLeft <= 7) && (
        <div className="bg-red-50 border border-red-300 rounded-xl p-4 flex items-start gap-3">
          <span className="text-red-500 flex-shrink-0 mt-0.5"><Ic.Alert /></span>
          <div className="flex-1">
            <p className="text-sm font-bold text-red-900">Immediate action required</p>
            <div className="mt-1.5 space-y-1">
              {DOCS.filter(d => d.daysLeft <= 7).map(d => (
                <p key={d.id} className="text-xs text-red-700">
                  <strong>{d.name}</strong> · {d.location} · expires {d.expiry} ({d.daysLeft === 1 ? '1 day' : `${d.daysLeft} days`})
                </p>
              ))}
            </div>
          </div>
        </div>
      )}

      {/* Filters */}
      <div className="flex flex-wrap items-center gap-2">
        <select
          value={brandFilter}
          onChange={e => setBrandFilter(e.target.value)}
          className="text-sm border border-stone-200 rounded-lg px-3 py-1.5 text-stone-700 bg-white focus:outline-none focus:border-teal-600 focus:ring-2 focus:ring-teal-600/20"
        >
          <option value="All">All Brands</option>
          <option value="burgercraft">BurgerCraft</option>
          <option value="tacoverde">Taco Verde</option>
        </select>

        <div className="flex gap-1.5 flex-wrap">
          {docTypes.map(t => (
            <button
              key={t}
              onClick={() => setTypeFilter(t)}
              className={`text-xs px-3 py-1.5 rounded-lg border font-semibold transition-all ${typeFilter === t ? 'bg-teal-700 text-white border-teal-700' : 'bg-white text-stone-600 border-stone-200 hover:border-stone-300 hover:text-stone-900'}`}
            >
              {t}
            </button>
          ))}
        </div>

        <button
          onClick={() => setSortBy(s => s === 'expiry' ? 'name' : 'expiry')}
          className="ml-auto text-xs text-stone-500 hover:text-stone-700 transition-colors font-medium"
        >
          Sort: {sortBy === 'expiry' ? 'Expiry ↑' : 'Name A–Z'}
        </button>
      </div>

      {/* Document list */}
      <div className="bg-white rounded-xl border border-stone-200 overflow-hidden">
        <div
          className="hidden md:grid px-5 py-2.5 bg-stone-50 border-b border-stone-100 gap-4 text-[10px] font-semibold uppercase tracking-widest text-stone-400"
          style={{ gridTemplateColumns: '2fr 1fr 1fr 150px' }}
        >
          <span>Document</span>
          <span>Type</span>
          <span>Location</span>
          <span className="text-right">Expires</span>
        </div>
        <div className="divide-y divide-stone-100">
          {filtered.map(doc => {
            const badge = expiryBadge(doc.daysLeft)
            const rowBg = doc.daysLeft <= 3 ? 'bg-red-50/60' : ''
            return (
              <div
                key={doc.id}
                className={`px-5 py-4 hover:bg-stone-50 transition-colors md:grid gap-4 items-center ${rowBg}`}
                style={{ gridTemplateColumns: '2fr 1fr 1fr 150px' }}
              >
                <div className="flex items-start gap-2.5 mb-2 md:mb-0">
                  <span className={`flex-shrink-0 mt-0.5 ${doc.daysLeft <= 30 ? 'text-red-400' : 'text-stone-300'}`}>
                    <Ic.FileText />
                  </span>
                  <div>
                    <p className="text-sm font-medium text-stone-900 leading-snug">{doc.name}</p>
                    <p className="text-xs text-stone-400 mt-0.5">{BRANDS[doc.brand].name}</p>
                  </div>
                </div>
                <div className="mb-1.5 md:mb-0">
                  <span className="text-xs font-medium text-stone-600 bg-stone-100 px-2 py-0.5 rounded">{doc.type}</span>
                </div>
                <p className="text-sm text-stone-600 mb-2 md:mb-0 truncate">{doc.location}</p>
                <div className="flex items-center justify-start md:justify-end gap-1.5">
                  {badge.alertIcon && <span className="text-red-500 flex-shrink-0"><Ic.Alert /></span>}
                  <span className={`text-xs px-2.5 py-1 rounded-full border font-semibold flex items-center gap-1.5 ${badge.cls}`}>
                    <span className={`w-1.5 h-1.5 rounded-full flex-shrink-0 ${badge.dot}`} />
                    {badge.label}
                  </span>
                </div>
              </div>
            )
          })}
        </div>
      </div>
    </div>
  )
}
