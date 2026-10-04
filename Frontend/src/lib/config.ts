import { type Brand, type NavItem, type Role } from '@/lib/types'

export const BRANDS: Record<Brand, { name: string; short: string; accent: string; bg: string; locations: number }> = {
  burgercraft: { name: 'BurgerCraft', short: 'BC', accent: '#EA5A0C', bg: '#FFF7ED', locations: 52 },
  tacoverde: { name: 'Taco Verde', short: 'TV', accent: '#15803D', bg: '#F0FDF4', locations: 38 },
}

export const ROLES: Record<Role, { label: string; name: string; initials: string }> = {
  corporate: { label: 'Corporate Admin', name: 'Alex Chen', initials: 'AC' },
  brand: { label: 'Brand Admin', name: 'Maria Santos', initials: 'MS' },
  manager: { label: 'Location Manager', name: 'Jordan Lee', initials: 'JL' },
  employee: { label: 'Employee', name: 'Sam Rivera', initials: 'SR' },
}


export const NAV_ITEMS: NavItem[] = [
  { id: 'dashboard', label: 'Dashboard', roles: ['corporate', 'brand', 'manager', 'employee'] },
  { id: 'knowledge', label: 'Knowledge', roles: ['corporate', 'brand', 'manager', 'employee'] },
  { id: 'tasks', label: 'Tasks', roles: ['corporate', 'brand', 'manager', 'employee'] },
  { id: 'training', label: 'Training', roles: ['corporate', 'brand', 'manager', 'employee'] },
  { id: 'compliance', label: 'Compliance', roles: ['corporate', 'brand'] },
]


export const DAY_LABELS_CONST = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']

// The mock data is pinned to this demo date so "today" / "overdue" stay stable.
// Must match DEMO_TODAY in backend/src/data/tasks.seed.ts.
export const TODAY = '2026-08-19'

export function getNavItems(role: Role): NavItem[] {
  return NAV_ITEMS.filter(item => item.roles.includes(role))
}
