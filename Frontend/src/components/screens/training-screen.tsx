'use client'

import { useState, useCallback } from 'react'
import { Ic } from '@/components/icons'
import { AnimatedBar, AnimatedRing, Confetti, SuccessToast, useReducedMotion } from '@/components/motion'
import { LeaderboardRow, PodiumBar } from '@/components/training/leaderboard'
import { RedeemModal, RedemptionCode, RewardCard } from '@/components/training/rewards'
import { TodaysChallenge } from '@/components/training/todays-challenge'
import { QuizTimer, XPBar } from '@/components/training/xp'
import { ACHIEVEMENTS, COURSES, LEADERBOARD, PLAYER, QUIZ_QUESTIONS, REWARDS, type Reward } from '@/lib/mock-data'

export function TrainingScreen() {
  const [view, setView] = useState<'courses' | 'quiz' | 'leaderboard' | 'rewards'>('courses')
  const [quizCourseTitle, setQuizCourseTitle] = useState('Brand Standards: BurgerCraft')
  const [qIdx, setQIdx] = useState(0)
  const [selected, setSelected] = useState<number | null>(null)
  const [confirmed, setConfirmed] = useState(false)
  const [timedOut, setTimedOut] = useState(false)
  const [score, setScore] = useState(0)
  const [xpEarned, setXpEarned] = useState(0)
  const [streak, setStreak] = useState(0)
  const [showXpPop, setShowXpPop] = useState(false)
  const [xpPopVal, setXpPopVal] = useState(0)
  const [quizDone, setQuizDone] = useState(false)
  const [timerKey, setTimerKey] = useState(0)
  const [showDoneToast, setShowDoneToast] = useState(false)
  const [doneConfetti, setDoneConfetti] = useState(false)
  const [spendableXp, setSpendableXp] = useState(PLAYER.xp)
  const [pendingReward, setPendingReward] = useState<Reward | null>(null)
  const [redeemedReward, setRedeemedReward] = useState<{ reward: Reward; code: string; xpLeft: number } | null>(null)
  const [rewardConfetti, setRewardConfetti] = useState(false)
  const [showRewardToast, setShowRewardToast] = useState(false)
  const reduced = useReducedMotion()

  const totalRequired = COURSES.filter(c => c.required).length
  const completedRequired = COURSES.filter(c => c.required && c.progress === 100).length
  const q = QUIZ_QUESTIONS[qIdx]

  function startQuiz(title: string) {
    setQuizCourseTitle(title)
    setQIdx(0); setSelected(null); setConfirmed(false); setTimedOut(false)
    setScore(0); setXpEarned(0); setStreak(0)
    setQuizDone(false); setDoneConfetti(false); setShowDoneToast(false)
    setTimerKey(k => k + 1)
    setView('quiz')
  }

  function handleExpire() {
    if (!confirmed) { setTimedOut(true); setConfirmed(true); setStreak(0) }
  }

  function handleConfirm() {
    if (selected === null && !timedOut) return
    setConfirmed(true)
    const isCorrect = selected === q.correct
    if (isCorrect) {
      const bonus = streak >= 2 ? Math.round(q.xp * 0.5) : 0
      const total = q.xp + bonus
      setScore(s => s + 1); setXpEarned(x => x + total); setStreak(s => s + 1)
      setXpPopVal(total); setShowXpPop(true)
      setTimeout(() => setShowXpPop(false), 1800)
    } else {
      setStreak(0)
    }
  }

  function handleRedeemRequest(r: Reward) { setPendingReward(r) }

  function handleRedeemConfirm() {
    if (!pendingReward) return
    const newXp = spendableXp - pendingReward.cost
    const code = Math.random().toString(36).substring(2, 8).toUpperCase()
    setSpendableXp(newXp)
    setRedeemedReward({ reward: pendingReward, code, xpLeft: newXp })
    setPendingReward(null)
    setRewardConfetti(true)
    setShowRewardToast(true)
    setTimeout(() => { setRewardConfetti(false); setShowRewardToast(false) }, 3000)
  }

  const handleNext = useCallback(() => {
    if (qIdx < QUIZ_QUESTIONS.length - 1) {
      setQIdx(i => i + 1); setSelected(null); setConfirmed(false)
      setTimedOut(false); setTimerKey(k => k + 1)
    } else {
      setQuizDone(true)
      setDoneConfetti(true); setShowDoneToast(true)
      setTimeout(() => { setDoneConfetti(false); setShowDoneToast(false) }, 3000)
    }
  }, [qIdx])

  return (
    <div className="p-4 md:p-6 max-w-4xl mx-auto space-y-4">

      {/* ── Courses view ─────────────────────────────────────── */}
      {view === 'courses' && (
        <>
          <div className="flex items-start justify-between flex-wrap gap-3">
            <div>
              <h1 className="text-xl font-semibold text-stone-900">Training</h1>
              <p className="text-xs text-stone-500 mt-0.5">{completedRequired}/{totalRequired} required courses complete</p>
            </div>
            <div className="flex items-center gap-2">
              <button
                onClick={() => setView('rewards')}
                className="flex items-center gap-1.5 text-xs font-semibold text-amber-700 border border-amber-200 bg-amber-50 hover:bg-amber-100 active:scale-[0.97] px-3.5 py-2 rounded-lg transition-all"
              >
                <span>🎁</span> Rewards
              </button>
              <button
                onClick={() => setView('leaderboard')}
                className="flex items-center gap-1.5 text-xs font-semibold text-teal-700 border border-teal-200 bg-teal-50 hover:bg-teal-100 active:scale-[0.97] px-3.5 py-2 rounded-lg transition-all"
              >
                <span>🏆</span> Leaderboard
              </button>
            </div>
          </div>

          {/* Player card */}
          <div className="bg-white rounded-xl border border-stone-200 p-5">
            <div className="flex items-center gap-4 mb-4">
              <div className="w-12 h-12 rounded-xl bg-teal-100 flex items-center justify-center text-xl flex-shrink-0">🎮</div>
              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2 flex-wrap">
                  <p className="text-sm font-semibold text-stone-900">{PLAYER.name}</p>
                  <span className="text-[10px] font-bold uppercase tracking-wide text-teal-700 bg-teal-50 border border-teal-200 px-2 py-0.5 rounded-full">
                    Level {PLAYER.level}
                  </span>
                  <span className="text-[10px] font-bold text-amber-600 bg-amber-50 border border-amber-200 px-2 py-0.5 rounded-full">
                    🔥 {PLAYER.streak}-day streak
                  </span>
                </div>
                <p className="text-xs text-stone-400 mt-0.5 font-mono">{spendableXp.toLocaleString()} / {PLAYER.xpToNext.toLocaleString()} XP</p>
              </div>
              <div className="text-right flex-shrink-0">
                <p className="text-xs text-stone-400">Team rank</p>
                <p className="text-2xl font-mono font-bold text-teal-700">#{PLAYER.rank}</p>
              </div>
            </div>
            {/* XP to next level */}
            <div className="mb-3">
              <div className="flex items-center justify-between mb-1">
                <p className="text-[10px] text-stone-400 font-semibold uppercase tracking-widest">Level progress</p>
                <p className="text-[10px] text-stone-400 font-mono">{Math.max(0, PLAYER.xpToNext - spendableXp)} XP to Level {PLAYER.level + 1}</p>
              </div>
              <XPBar current={spendableXp} max={PLAYER.xpToNext} animate delay={100} />
            </div>

            {/* Next reward */}
            {(() => {
              const next = REWARDS.find(r => r.cost > spendableXp)
              if (!next) return (
                <div className="flex items-center gap-2 bg-emerald-50 border border-emerald-100 rounded-lg px-3 py-2">
                  <span className="text-base">🎉</span>
                  <p className="text-xs font-semibold text-emerald-700">All rewards unlocked!</p>
                </div>
              )
              const xpNeeded = next.cost - spendableXp
              const pct = (spendableXp / next.cost) * 100
              return (
                <button
                  onClick={() => setView('rewards')}
                  className="w-full text-left bg-amber-50 border border-amber-100 rounded-lg px-3 py-2.5 hover:bg-amber-100 active:scale-[0.99] transition-all group"
                >
                  <div className="flex items-center justify-between mb-1.5">
                    <div className="flex items-center gap-2">
                      <span className="text-base leading-none">{next.icon}</span>
                      <p className="text-xs font-semibold text-stone-800">{next.label}</p>
                    </div>
                    <div className="flex items-center gap-1.5">
                      <span className="text-[10px] font-mono font-bold text-amber-700">{xpNeeded.toLocaleString()} XP away</span>
                      <span className="text-stone-300 group-hover:text-amber-500 transition-colors"><Ic.ChevronRight /></span>
                    </div>
                  </div>
                  <div className="w-full bg-amber-100 rounded-full h-1.5 overflow-hidden">
                    <div
                      className="h-1.5 rounded-full bg-amber-400"
                      style={{ width: `${reduced ? pct : 0}%`, transition: reduced ? 'none' : 'width 0.8s cubic-bezier(0.4,0,0.2,1) 0.2s' }}
                      ref={el => { if (el && !reduced) requestAnimationFrame(() => { el.style.width = `${pct}%` }) }}
                    />
                  </div>
                </button>
              )
            })()}
          </div>

          {/* Achievements row */}
          <div className="bg-white rounded-xl border border-stone-200 p-5">
            <p className="text-[11px] font-semibold text-stone-400 uppercase tracking-widest mb-3">Achievements</p>
            <div className="flex gap-2.5 flex-wrap">
              {ACHIEVEMENTS.map((a, i) => (
                <div
                  key={a.id}
                  title={`${a.label}: ${a.desc}`}
                  className={`flex flex-col items-center gap-1 w-[72px] p-2 rounded-xl border cursor-default transition-shadow ${a.earned ? 'border-teal-200 bg-teal-50 hover:shadow-sm' : 'border-stone-100 bg-stone-50 opacity-50 grayscale'}`}
                  style={{
                    opacity: 0,
                    animation: reduced ? 'none' : `fadeScaleIn 0.4s ease forwards`,
                    animationDelay: reduced ? '0s' : `${i * 60 + 80}ms`,
                  }}
                >
                  <span className="text-2xl leading-none">{a.icon}</span>
                  <span className={`text-[9px] font-semibold text-center leading-tight ${a.earned ? 'text-teal-800' : 'text-stone-400'}`}>{a.label}</span>
                </div>
              ))}
            </div>
          </div>

          {/* Today's Challenge */}
          <TodaysChallenge />

          {/* Required progress */}
          <div className="bg-white rounded-xl border border-stone-200 p-5 flex items-center gap-5">
            <AnimatedRing pct={Math.round((completedRequired / totalRequired) * 100)} size={56} delay={150} />
            <div className="flex-1">
              <p className="text-sm font-semibold text-stone-900">Required Training Progress</p>
              <p className="text-xs text-stone-500 mt-0.5">{completedRequired} of {totalRequired} mandatory courses complete</p>
              <div className="w-full bg-stone-100 rounded-full h-1.5 mt-2.5 overflow-hidden">
                <AnimatedBar pct={(completedRequired / totalRequired) * 100} color="#0F766E" delay={200} />
              </div>
            </div>
          </div>

          {/* Course cards */}
          <div className="grid md:grid-cols-2 gap-3">
            {COURSES.map((course, idx) => (
              <div
                key={course.id}
                className="bg-white rounded-xl border border-stone-200 p-5 transition-all duration-150 hover:-translate-y-0.5 hover:shadow-md active:translate-y-0 active:shadow-sm group"
                style={{
                  opacity: 0,
                  animation: reduced ? 'none' : `fadeSlideIn 0.35s ease forwards`,
                  animationDelay: reduced ? '0s' : `${idx * 70}ms`,
                }}
              >
                <div className="flex items-start gap-3 mb-3">
                  <div className="w-10 h-10 rounded-xl bg-stone-50 border border-stone-100 flex items-center justify-center text-xl flex-shrink-0 group-hover:border-teal-200 group-hover:bg-teal-50 transition-all">
                    {course.icon}
                  </div>
                  <div className="flex-1 min-w-0">
                    <div className="flex gap-1.5 mb-1.5 flex-wrap">
                      {course.required && (
                        <span className="text-[10px] font-bold uppercase tracking-wide text-red-600 bg-red-50 border border-red-100 px-1.5 py-0.5 rounded">Required</span>
                      )}
                      {course.progress === 100 && (
                        <span className="text-[10px] font-bold uppercase tracking-wide text-emerald-600 bg-emerald-50 border border-emerald-100 px-1.5 py-0.5 rounded">✓ Complete</span>
                      )}
                    </div>
                    <p className="text-sm font-semibold text-stone-900 leading-snug">{course.title}</p>
                    <p className="text-xs text-stone-400 mt-1">{course.modules} modules · {course.duration}</p>
                  </div>
                </div>
                <div className="flex items-center justify-between mb-2">
                  <p className="text-xs text-stone-500 font-mono">{course.progress}%</p>
                  <span className="text-[10px] font-bold text-amber-600 bg-amber-50 border border-amber-100 px-2 py-0.5 rounded-full">+{course.xp} XP</span>
                </div>
                <div className="w-full bg-stone-100 rounded-full h-1.5 mb-3.5 overflow-hidden">
                  <AnimatedBar
                    pct={course.progress}
                    color={course.progress === 100 ? '#16A34A' : '#0F766E'}
                    delay={120 + idx * 60}
                  />
                </div>
                <button
                  onClick={() => startQuiz(course.title)}
                  className={`w-full py-2 rounded-lg text-xs font-semibold transition-all active:scale-[0.97] ${course.progress === 100 ? 'bg-stone-100 text-stone-500 hover:bg-stone-200' : 'bg-teal-700 text-white hover:bg-teal-800'}`}
                >
                  {course.progress === 100 ? 'Replay Quiz' : course.progress > 0 ? 'Continue →' : 'Start Course →'}
                </button>
              </div>
            ))}
          </div>
        </>
      )}

      {/* ── Leaderboard view ─────────────────────────────────── */}
      {view === 'leaderboard' && (
        <div className="max-w-xl mx-auto">
          <button
            onClick={() => setView('courses')}
            className="flex items-center gap-1 text-sm text-stone-500 hover:text-stone-900 transition-colors mb-4"
          >
            <Ic.ChevronLeft /> Back to Training
          </button>

          <div className="flex items-center justify-between mb-4">
            <div>
              <h1 className="text-xl font-semibold text-stone-900">Team Leaderboard</h1>
              <p className="text-xs text-stone-500 mt-0.5">Downtown Flagship · This month</p>
            </div>
            <span className="text-2xl">🏆</span>
          </div>

          {/* Top 3 podium */}
          <div className="flex items-end justify-center gap-3 mb-5 px-2">
            {([LEADERBOARD[1], LEADERBOARD[0], LEADERBOARD[2]] as typeof LEADERBOARD).map((p, podiumIdx) => (
              <PodiumBar key={p.rank} p={p} podiumIdx={podiumIdx} reduced={reduced} />
            ))}
          </div>

          {/* Full list */}
          <div className="bg-white rounded-xl border border-stone-200 overflow-hidden">
            <div className="px-5 py-2.5 bg-stone-50 border-b border-stone-100 grid gap-3 text-[10px] font-semibold uppercase tracking-widest text-stone-400"
              style={{ gridTemplateColumns: '32px 1fr 64px 72px' }}>
              <span>#</span><span>Name</span><span className="text-right">Streak</span><span className="text-right">XP</span>
            </div>
            <div className="divide-y divide-stone-100">
              {LEADERBOARD.map((p, rowIdx) => (
                <LeaderboardRow key={p.rank} p={p} rowIdx={rowIdx} reduced={reduced} />
              ))}
            </div>
          </div>
        </div>
      )}

      {/* ── Rewards view ─────────────────────────────────────── */}
      {view === 'rewards' && (
        <div className="max-w-2xl mx-auto">
          {pendingReward && (
            <RedeemModal
              reward={pendingReward}
              spendableXp={spendableXp}
              onConfirm={handleRedeemConfirm}
              onCancel={() => setPendingReward(null)}
            />
          )}
          {redeemedReward && (
            <RedemptionCode
              reward={redeemedReward.reward}
              code={redeemedReward.code}
              xpLeft={redeemedReward.xpLeft}
              onDone={() => setRedeemedReward(null)}
            />
          )}

          <button
            onClick={() => setView('courses')}
            className="flex items-center gap-1 text-sm text-stone-500 hover:text-stone-900 transition-colors mb-4"
          >
            <Ic.ChevronLeft /> Back to Training
          </button>

          {/* Header */}
          <div className="flex items-center justify-between mb-4">
            <div>
              <h1 className="text-xl font-semibold text-stone-900">Rewards</h1>
              <p className="text-xs text-stone-500 mt-0.5">Spend your XP on real perks</p>
            </div>
            <span className="text-2xl">🎁</span>
          </div>

          {/* XP balance card */}
          <div className="bg-white rounded-xl border border-stone-200 p-5 mb-4">
            <div className="flex items-center justify-between mb-3">
              <div className="flex items-center gap-3">
                <div className="w-10 h-10 rounded-xl bg-amber-50 border border-amber-100 flex items-center justify-center text-xl">⚡</div>
                <div>
                  <p className="text-xs text-stone-400 font-semibold uppercase tracking-widest">Your XP Balance</p>
                  <p className="text-2xl font-mono font-bold text-stone-900">{spendableXp.toLocaleString()}</p>
                </div>
              </div>
              <div className="text-right">
                <p className="text-xs text-stone-400">Unlocked rewards</p>
                <p className="text-xl font-mono font-bold text-emerald-600">{REWARDS.filter(r => spendableXp >= r.cost).length}/{REWARDS.length}</p>
              </div>
            </div>
            <div className="w-full bg-stone-100 rounded-full h-2 overflow-hidden">
              <AnimatedBar pct={(spendableXp / REWARDS[REWARDS.length - 1].cost) * 100} color="#F59E0B" delay={80} />
            </div>
            <p className="text-[10px] text-stone-400 mt-1.5 font-mono">
              {REWARDS.find(r => r.cost > spendableXp)
                ? `${(REWARDS.find(r => r.cost > spendableXp)!.cost - spendableXp).toLocaleString()} XP until next reward`
                : 'All rewards unlocked!'}
            </p>
          </div>

          {/* Reward grid */}
          {(() => {
            const categories = [...new Set(REWARDS.map(r => r.category))]
            return categories.map(cat => (
              <div key={cat} className="mb-5">
                <p className="text-[11px] font-semibold text-stone-400 uppercase tracking-widest mb-3">{cat}</p>
                <div className="grid md:grid-cols-2 gap-3">
                  {REWARDS.filter(r => r.category === cat).map((reward, idx) => (
                    <div
                      key={reward.id}
                      style={{
                        opacity: 0,
                        animation: reduced ? 'none' : `fadeSlideIn 0.32s ease forwards`,
                        animationDelay: reduced ? '0s' : `${idx * 60 + 40}ms`,
                      }}
                    >
                      <RewardCard reward={reward} spendableXp={spendableXp} onRedeem={handleRedeemRequest} />
                    </div>
                  ))}
                </div>
              </div>
            ))
          })()}

          <p className="text-xs text-stone-400 text-center pb-2">
            Rewards are approved by your location manager. XP is earned through training completions and daily challenges.
          </p>
        </div>
      )}

      {/* Confetti + toast for reward redemption */}
      <SuccessToast show={showRewardToast} message="Reward redeemed!" sub="Show the code to your manager to claim" />

      {/* ── Quiz view ─────────────────────────────────────────── */}
      {view === 'quiz' && (
        <div className="max-w-xl mx-auto relative">
          {/* XP pop */}
          <div
            className="fixed top-20 left-1/2 z-50 pointer-events-none"
            style={{
              transform: `translateX(-50%) translateY(${showXpPop ? '0' : '-16px'})`,
              opacity: showXpPop ? 1 : 0,
              transition: reduced ? 'none' : 'transform 0.3s cubic-bezier(0.34,1.56,0.64,1), opacity 0.2s ease',
            }}
          >
            <div className="bg-teal-700 text-white text-sm font-bold px-5 py-2.5 rounded-full shadow-lg flex items-center gap-2">
              <span>⚡</span>
              <span>+{xpPopVal} XP{streak >= 2 ? ` · ${streak}x streak!` : ''}</span>
            </div>
          </div>

          <SuccessToast show={showDoneToast} message="Quiz complete!" sub={`${score}/${QUIZ_QUESTIONS.length} correct · +${xpEarned} XP`} />

          <button
            onClick={() => setView('courses')}
            className="flex items-center gap-1 text-sm text-stone-500 hover:text-stone-900 transition-colors mb-4"
          >
            <Ic.ChevronLeft /> Back to Courses
          </button>

          {/* Quiz completed */}
          {quizDone ? (
            <div className="relative bg-white rounded-xl border border-stone-200 p-8 text-center overflow-hidden">
              <Confetti active={doneConfetti} />
              <div className="text-5xl mb-4" style={{ animation: reduced ? 'none' : 'bounceIn 0.5s cubic-bezier(0.34,1.56,0.64,1)' }}>
                {score >= 4 ? '🏆' : score >= 3 ? '🎯' : '📚'}
              </div>
              <h2 className="text-xl font-bold text-stone-900 mb-1">Quiz Complete!</h2>
              <p className="text-stone-500 text-sm mb-6">{quizCourseTitle}</p>
              <div className="grid grid-cols-3 gap-3 mb-6">
                {[
                  { label: 'Correct', value: `${score}/${QUIZ_QUESTIONS.length}`, cls: 'bg-stone-50' },
                  { label: 'XP Earned', value: `+${xpEarned}`, cls: 'bg-teal-50 border border-teal-100' },
                  { label: 'Score', value: `${Math.round((score / QUIZ_QUESTIONS.length) * 100)}%`, cls: 'bg-amber-50 border border-amber-100' },
                ].map((stat, i) => (
                  <div
                    key={stat.label}
                    className={`rounded-xl p-4 ${stat.cls}`}
                    style={{
                      opacity: 0,
                      animation: reduced ? 'none' : `fadeScaleIn 0.4s ease forwards`,
                      animationDelay: reduced ? '0s' : `${i * 80 + 100}ms`,
                    }}
                  >
                    <p className="text-2xl font-mono font-bold text-stone-900">{stat.value}</p>
                    <p className="text-xs text-stone-400 mt-1">{stat.label}</p>
                  </div>
                ))}
              </div>
              {score === QUIZ_QUESTIONS.length && (
                <div className="bg-emerald-50 border border-emerald-200 rounded-xl p-3 mb-5 text-sm text-emerald-800 font-semibold">
                  🎯 Perfect score! Achievement unlocked.
                </div>
              )}
              <div className="flex gap-3">
                <button
                  onClick={() => startQuiz(quizCourseTitle)}
                  className="flex-1 py-2.5 rounded-xl text-sm font-semibold border border-stone-200 text-stone-700 hover:bg-stone-50 active:scale-[0.98] transition-all"
                >
                  Retry Quiz
                </button>
                <button
                  onClick={() => setView('courses')}
                  className="flex-1 py-2.5 rounded-xl text-sm font-semibold text-white bg-teal-700 hover:bg-teal-800 active:scale-[0.98] transition-all"
                >
                  Back to Courses
                </button>
              </div>
            </div>
          ) : (
            <>
              <div className="bg-white rounded-xl border border-stone-200 p-4 mb-4">
                <div className="flex items-center justify-between mb-3">
                  <div className="flex-1 min-w-0">
                    <p className="text-[11px] font-semibold text-stone-400 uppercase tracking-widest mb-0.5">{quizCourseTitle}</p>
                    <p className="text-sm font-semibold text-stone-900">Knowledge Check</p>
                  </div>
                  <QuizTimer key={timerKey} seconds={20} onExpire={handleExpire} />
                </div>
                <div className="flex items-center gap-3">
                  <div className="flex-1 bg-stone-100 rounded-full h-1.5 overflow-hidden">
                    <div
                      className="bg-teal-700 h-1.5 rounded-full"
                      style={{ width: `${((qIdx + (confirmed ? 1 : 0)) / QUIZ_QUESTIONS.length) * 100}%`, transition: 'width 0.4s ease' }}
                    />
                  </div>
                  <span className="text-xs font-mono text-stone-400 flex-shrink-0 tabular-nums">{qIdx + 1}/{QUIZ_QUESTIONS.length}</span>
                </div>
                <div className="flex items-center gap-4 mt-3 pt-3 border-t border-stone-100">
                  <div className="flex items-center gap-1.5">
                    <span className="text-xs text-stone-400">Score</span>
                    <span className="text-xs font-mono font-bold text-stone-700 tabular-nums">{score}/{qIdx + (confirmed ? 1 : 0)}</span>
                  </div>
                  <div className="flex items-center gap-1.5">
                    <span className="text-xs text-stone-400">XP</span>
                    <span className="text-xs font-mono font-bold text-teal-700 tabular-nums">+{xpEarned}</span>
                  </div>
                  {streak >= 2 && (
                    <div className="flex items-center gap-1 ml-auto bg-amber-50 border border-amber-100 px-2.5 py-0.5 rounded-full">
                      <span className="text-xs">🔥</span>
                      <span className="text-xs font-bold text-amber-600">{streak}x streak</span>
                    </div>
                  )}
                </div>
              </div>

              <div className="bg-white rounded-xl border border-stone-200 p-6">
                <p className="text-base font-semibold text-stone-900 leading-snug mb-5">{q.text}</p>
                <div className="space-y-2.5">
                  {q.options.map((opt, i) => {
                    const isSelected = selected === i
                    const isCorrect = i === q.correct
                    let cls = 'border-stone-200 text-stone-700 hover:border-stone-300 hover:bg-stone-50 active:scale-[0.99]'
                    let letterCls = 'border-stone-300 text-stone-400'
                    if (confirmed && isCorrect) { cls = 'border-emerald-500 bg-emerald-50 text-emerald-900 cursor-default'; letterCls = 'border-emerald-500 bg-emerald-500 text-white' }
                    else if (confirmed && isSelected && !isCorrect) { cls = 'border-red-400 bg-red-50 text-red-800 cursor-default'; letterCls = 'border-red-400 bg-red-400 text-white' }
                    else if (confirmed) { cls = 'border-stone-100 text-stone-400 cursor-default' }
                    else if (isSelected) { cls = 'border-teal-600 bg-teal-50 text-teal-900 active:scale-[0.99]'; letterCls = 'border-teal-600 bg-teal-600 text-white' }
                    return (
                      <button
                        key={i}
                        onClick={() => !confirmed && setSelected(i)}
                        className={`w-full text-left px-4 py-3.5 rounded-xl border-2 text-sm flex items-start gap-3 transition-all ${cls}`}
                        style={{
                          transform: (confirmed && isCorrect && !reduced) ? 'scale(1.015)' : undefined,
                          transition: reduced ? 'none' : 'all 0.18s ease',
                        }}
                      >
                        <span className={`w-5 h-5 rounded-full border-2 flex-shrink-0 flex items-center justify-center text-[10px] font-bold mt-0.5 transition-all ${letterCls}`}>
                          {String.fromCharCode(65 + i)}
                        </span>
                        <span>{opt}</span>
                        {confirmed && isCorrect && <span className="ml-auto flex-shrink-0 text-emerald-500">✓</span>}
                        {confirmed && isSelected && !isCorrect && <span className="ml-auto flex-shrink-0 text-red-400">✗</span>}
                      </button>
                    )
                  })}
                </div>

                {confirmed && (
                  <div
                    className={`mt-4 p-4 rounded-xl text-sm leading-relaxed border ${selected === q.correct ? 'bg-emerald-50 text-emerald-800 border-emerald-200' : timedOut ? 'bg-stone-50 text-stone-700 border-stone-200' : 'bg-red-50 text-red-800 border-red-200'}`}
                    style={{ animation: reduced ? 'none' : 'fadeSlideIn 0.25s ease' }}
                  >
                    <p className="font-bold mb-1 flex items-center gap-2 flex-wrap">
                      {selected === q.correct
                        ? <><span>✓ Correct</span><span className="text-xs font-mono bg-emerald-100 text-emerald-700 px-2 py-0.5 rounded-full">+{q.xp}{streak >= 2 ? ` + ${Math.round(q.xp * 0.5)} bonus` : ''} XP</span></>
                        : timedOut ? <span>⏱ Time&apos;s up</span>
                        : <span>✗ Not quite</span>
                      }
                    </p>
                    <p>{q.explanation}</p>
                  </div>
                )}

                <div className="mt-5">
                  {!confirmed ? (
                    <button
                      onClick={handleConfirm}
                      disabled={selected === null}
                      className="w-full py-2.5 rounded-xl text-sm font-semibold text-white bg-teal-700 disabled:opacity-40 disabled:cursor-not-allowed hover:bg-teal-800 active:scale-[0.98] transition-all"
                    >
                      Submit Answer
                    </button>
                  ) : (
                    <button
                      onClick={handleNext}
                      className="w-full py-2.5 rounded-xl text-sm font-semibold text-white bg-teal-700 hover:bg-teal-800 active:scale-[0.98] transition-all"
                    >
                      {qIdx < QUIZ_QUESTIONS.length - 1 ? 'Next Question →' : 'See Results →'}
                    </button>
                  )}
                </div>
              </div>
            </>
          )}
        </div>
      )}
    </div>
  )
}
