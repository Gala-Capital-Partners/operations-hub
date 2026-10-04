import type { Metadata } from 'next'
import type { ReactNode } from 'react'
import { SessionProvider } from '@/components/session-provider'
// Fonts are self-hosted via Fontsource (same DM Sans / JetBrains Mono as the Figma design),
// so the app works offline and doesn't depend on reaching Google Fonts at build time.
import '@fontsource-variable/dm-sans/opsz.css'
import '@fontsource/jetbrains-mono/400.css'
import '@fontsource/jetbrains-mono/500.css'
import './globals.css'

export const metadata: Metadata = {
  title: 'OpsHub · GalaPartnerAtlas',
  description:
    'An internal platform unifying operations and sales analytics for multi-brand restaurants, streamlining tasks, training, compliance, and knowledge access.',
  robots: { index: false },
}

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>
        <SessionProvider>{children}</SessionProvider>
      </body>
    </html>
  )
}
