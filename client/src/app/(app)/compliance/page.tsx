import type { Metadata } from 'next'
import { ComplianceScreen } from '@/components/screens/compliance-screen'

export const metadata: Metadata = { title: 'Compliance · OpsHub' }

export default function Page() {
  return <ComplianceScreen />
}
