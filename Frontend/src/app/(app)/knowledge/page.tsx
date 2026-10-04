import type { Metadata } from 'next'
import { KnowledgeScreen } from '@/components/screens/knowledge-screen'

export const metadata: Metadata = { title: 'Knowledge · OpsHub' }

export default function Page() {
  return <KnowledgeScreen />
}
