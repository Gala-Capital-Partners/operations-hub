import type { Metadata } from 'next'
import { TrainingScreen } from '@/components/screens/training-screen'

export const metadata: Metadata = { title: 'Training · OpsHub' }

export default function Page() {
  return <TrainingScreen />
}
