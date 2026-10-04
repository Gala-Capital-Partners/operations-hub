'use client'

import { useState } from 'react'
import { Ic } from '@/components/icons'
import { KB_ARTICLES, KB_FOLDERS } from '@/lib/mock-data'

export function KnowledgeScreen() {
  const [view, setView] = useState<'folders' | 'articles' | 'reader'>('folders')
  const [query, setQuery] = useState('')
  const [activeFolder, setActiveFolder] = useState<string | null>(null)
  const [activeArticle, setActiveArticle] = useState<number | null>(null)

  const folderIcons = ['◈', '◉', '◫', '◐', '⬡', '▶']

  return (
    <div className="p-4 md:p-6 max-w-4xl mx-auto space-y-4">
      {/* Breadcrumb / back */}
      <div className="flex items-center gap-2">
        {view !== 'folders' && (
          <button
            onClick={() => { if (view === 'reader') setView('articles'); else setView('folders') }}
            className="flex items-center gap-1 text-sm text-stone-500 hover:text-stone-900 transition-colors"
          >
            <Ic.ChevronLeft />
            {view === 'reader' ? KB_FOLDERS.find(f => f.id === activeFolder)?.label : 'Knowledge Base'}
          </button>
        )}
        {view === 'folders' && <h1 className="text-xl font-semibold text-stone-900">Knowledge Base</h1>}
      </div>

      {/* Search — always visible */}
      <div className="relative">
        <span className="absolute left-3.5 top-1/2 -translate-y-1/2 text-stone-400 pointer-events-none"><Ic.Search /></span>
        <input
          type="search"
          placeholder="Search articles, SOPs, policies…"
          value={query}
          onChange={e => setQuery(e.target.value)}
          className="w-full border border-stone-200 rounded-xl pl-10 pr-4 py-2.5 text-sm text-stone-900 placeholder:text-stone-400 focus:outline-none focus:border-teal-600 focus:ring-2 focus:ring-teal-600/20 bg-white transition-all"
        />
      </div>

      {/* Folder grid */}
      {view === 'folders' && (
        <div className="grid grid-cols-2 md:grid-cols-3 gap-3">
          {KB_FOLDERS.map((folder, i) => (
            <button
              key={folder.id}
              onClick={() => { setActiveFolder(folder.id); setView('articles') }}
              className="bg-white border border-stone-200 rounded-xl p-5 text-left hover:border-teal-300 hover:shadow-sm transition-all group"
            >
              <div className="text-2xl text-stone-300 group-hover:text-teal-600 mb-3 transition-colors">{folderIcons[i]}</div>
              <p className="text-sm font-semibold text-stone-900">{folder.label}</p>
              <p className="text-xs text-stone-400 mt-0.5">{folder.count} articles</p>
            </button>
          ))}
        </div>
      )}

      {/* Article list */}
      {view === 'articles' && (
        <div className="bg-white rounded-xl border border-stone-200 overflow-hidden">
          <div className="px-5 py-3 bg-stone-50 border-b border-stone-200 flex items-center gap-2">
            <span className="text-xl text-stone-300">{folderIcons[KB_FOLDERS.findIndex(f => f.id === activeFolder)]}</span>
            <p className="text-sm font-semibold text-stone-900">{KB_FOLDERS.find(f => f.id === activeFolder)?.label}</p>
          </div>
          <div className="divide-y divide-stone-100">
            {KB_ARTICLES.map(article => (
              <button
                key={article.id}
                onClick={() => { setActiveArticle(article.id); setView('reader') }}
                className="w-full px-5 py-4 text-left hover:bg-stone-50 transition-colors flex items-center gap-3 group"
              >
                <span className="text-stone-300 flex-shrink-0 group-hover:text-teal-600 transition-colors"><Ic.FileText /></span>
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-medium text-stone-900 truncate">{article.title}</p>
                  <p className="text-xs text-stone-400 mt-0.5">Updated {article.updated} · {article.readTime} read</p>
                </div>
                <span className="text-stone-300 flex-shrink-0"><Ic.ChevronRight /></span>
              </button>
            ))}
          </div>
        </div>
      )}

      {/* Article reader */}
      {view === 'reader' && activeArticle && (
        <div className="bg-white rounded-xl border border-stone-200 p-6 md:p-8 max-w-2xl">
          <div className="flex items-center gap-2 text-xs text-stone-400 mb-4 flex-wrap">
            <span className="bg-stone-100 text-stone-600 px-2 py-0.5 rounded font-medium">
              {KB_FOLDERS.find(f => f.id === activeFolder)?.label}
            </span>
            <span>·</span>
            <span>{KB_ARTICLES.find(a => a.id === activeArticle)?.readTime} read</span>
            <span>·</span>
            <span>Updated {KB_ARTICLES.find(a => a.id === activeArticle)?.updated}</span>
          </div>
          <h1 className="text-xl font-semibold text-stone-900 mb-6 leading-snug">
            {KB_ARTICLES.find(a => a.id === activeArticle)?.title}
          </h1>
          <div className="space-y-5 text-sm text-stone-700 leading-relaxed">
            <p>This procedure applies to all BurgerCraft and Taco Verde locations. The line check must be completed no later than 30 minutes before each service period begins. Failure to complete prior to service constitutes a critical compliance violation.</p>
            <div>
              <h3 className="text-xs font-semibold text-stone-900 uppercase tracking-widest mb-3">Required Equipment</h3>
              <ul className="space-y-1.5">
                {['Calibrated probe thermometer (NIST-certified)', 'Line check log — form FRM-LC-001', 'Sanitizer test strips (200–400 ppm range)', 'Date labels and label gun'].map(item => (
                  <li key={item} className="flex items-start gap-2">
                    <span className="w-1.5 h-1.5 bg-teal-600 rounded-full mt-1.5 flex-shrink-0" />
                    {item}
                  </li>
                ))}
              </ul>
            </div>
            <div>
              <h3 className="text-xs font-semibold text-stone-900 uppercase tracking-widest mb-3">Procedure</h3>
              <div className="space-y-2.5">
                {[
                  'Verify all hot-hold items are at or above 135°F (57°C)',
                  'Verify all cold items are at or below 41°F (5°C)',
                  'Check sanitizer concentration in all buckets',
                  'Confirm date labels on all prepped items are current',
                  'Verify adequate par levels for upcoming service period',
                  'Record all findings on FRM-LC-001 and sign off',
                ].map((step, i) => (
                  <div key={i} className="flex items-start gap-3">
                    <span className="text-[11px] font-mono font-semibold text-teal-700 bg-teal-50 px-1.5 py-0.5 rounded flex-shrink-0 leading-5">
                      {String(i + 1).padStart(2, '0')}
                    </span>
                    <span>{step}</span>
                  </div>
                ))}
              </div>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
