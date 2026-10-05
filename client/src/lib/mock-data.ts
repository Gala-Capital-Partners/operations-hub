import { type Brand } from '@/lib/types'

// Static mock data from the Figma Make export.
// Tasks are NOT here any more — they are served by the backend Tasks API.

export const SALES = [
  { day: 'M', today: 8420, yesterday: 7900 },
  { day: 'T', today: 9150, yesterday: 8300 },
  { day: 'W', today: 7800, yesterday: 8100 },
  { day: 'Th', today: 10200, yesterday: 9400 },
  { day: 'F', today: 11800, yesterday: 10900 },
  { day: 'Sa', today: 13400, yesterday: 12100 },
  { day: 'Su', today: 9600, yesterday: 9200 },
]


export const LOCATION_DATA = [
  { id: 1, name: 'Downtown Flagship', brand: 'burgercraft' as Brand, pct: 100, total: 14, done: 14, overdue: 0 },
  { id: 2, name: 'Midtown Mall', brand: 'burgercraft' as Brand, pct: 86, total: 14, done: 12, overdue: 0 },
  { id: 3, name: 'Airport Terminal B', brand: 'burgercraft' as Brand, pct: 57, total: 14, done: 8, overdue: 2 },
  { id: 4, name: 'Westside Commons', brand: 'tacoverde' as Brand, pct: 100, total: 12, done: 12, overdue: 0 },
  { id: 5, name: 'Harbor View', brand: 'tacoverde' as Brand, pct: 42, total: 12, done: 5, overdue: 3 },
  { id: 6, name: 'University District', brand: 'tacoverde' as Brand, pct: 75, total: 12, done: 9, overdue: 1 },
  { id: 7, name: 'North Park', brand: 'burgercraft' as Brand, pct: 21, total: 14, done: 3, overdue: 4 },
]

export const KB_FOLDERS = [
  { id: 'brand', label: 'Brand Standards', count: 24 },
  { id: 'food', label: 'Food Safety & HACCP', count: 31 },
  { id: 'hr', label: 'HR & Policies', count: 18 },
  { id: 'ops', label: 'Operations', count: 42 },
  { id: 'mkt', label: 'Marketing & Promos', count: 15 },
  { id: 'train', label: 'Training Materials', count: 27 },
]

export const KB_ARTICLES = [
  { id: 1, title: 'Line Check Procedure — Standard Operating Procedure', updated: '2 days ago', readTime: '4 min' },
  { id: 2, title: 'HACCP Critical Control Points Guide', updated: '1 week ago', readTime: '8 min' },
  { id: 3, title: 'Food Temperature Logging Requirements', updated: '3 days ago', readTime: '3 min' },
  { id: 4, title: 'Allergen Awareness and Cross-Contamination Prevention', updated: '2 weeks ago', readTime: '6 min' },
  { id: 5, title: 'Opening Procedures: Complete Checklist Guide', updated: '1 month ago', readTime: '5 min' },
]

export const DOCS = [
  { id: 1, name: 'BurgerCraft Franchise Agreement — Downtown', type: 'Franchise Agreement', location: 'Downtown Flagship', brand: 'burgercraft' as Brand, expiry: '2025-08-15', daysLeft: 17 },
  { id: 2, name: 'Lease — Midtown Mall Unit 4B', type: 'Lease', location: 'Midtown Mall', brand: 'burgercraft' as Brand, expiry: '2025-09-30', daysLeft: 63 },
  { id: 3, name: 'Taco Verde License Amendment #3', type: 'Amendment', location: 'All Locations', brand: 'tacoverde' as Brand, expiry: '2026-03-15', daysLeft: 229 },
  { id: 4, name: 'Harbor View Lease Renewal', type: 'Renewal', location: 'Harbor View', brand: 'tacoverde' as Brand, expiry: '2025-10-01', daysLeft: 64 },
  { id: 5, name: 'Airport Terminal B — License Agreement', type: 'Franchise Agreement', location: 'Airport Terminal B', brand: 'burgercraft' as Brand, expiry: '2026-12-31', daysLeft: 336 },
  { id: 6, name: 'University District Lease', type: 'Lease', location: 'University District', brand: 'tacoverde' as Brand, expiry: '2027-06-30', daysLeft: 700 },
  { id: 7, name: 'North Park Franchise Agreement', type: 'Franchise Agreement', location: 'North Park', brand: 'burgercraft' as Brand, expiry: '2025-07-31', daysLeft: 3 },
  { id: 8, name: 'Westside Commons Amendment #1', type: 'Amendment', location: 'Westside Commons', brand: 'tacoverde' as Brand, expiry: '2026-08-15', daysLeft: 382 },
]

export const COURSES = [
  { id: 1, title: 'Food Safety Fundamentals', modules: 6, duration: '45 min', progress: 100, required: true, xp: 250, icon: '🛡️' },
  { id: 2, title: 'Brand Standards: BurgerCraft', modules: 4, duration: '30 min', progress: 67, required: true, xp: 180, icon: '🍔' },
  { id: 3, title: 'Opening & Closing Procedures', modules: 5, duration: '35 min', progress: 40, required: false, xp: 150, icon: '🔑' },
  { id: 4, title: 'Customer Service Excellence', modules: 7, duration: '50 min', progress: 0, required: false, xp: 200, icon: '⭐' },
  { id: 5, title: 'HACCP Certification Prep', modules: 8, duration: '60 min', progress: 0, required: true, xp: 320, icon: '📋' },
]

export const PLAYER = {
  name: 'Sam Rivera',
  level: 4,
  xp: 1240,
  xpToNext: 1500,
  streak: 7,
  totalCompleted: 12,
  rank: 2,
}

export const REWARDS = [
  { id: 1, icon: '🥤', label: 'Free Drink', desc: 'Any fountain drink or hot beverage during your shift', cost: 200, category: 'Perks' },
  { id: 2, icon: '🍟', label: 'Free Side', desc: 'Any side item — fries, rings, or chips', cost: 350, category: 'Perks' },
  { id: 3, icon: '🍔', label: 'Free Employee Meal', desc: 'One full combo meal — your choice', cost: 600, category: 'Perks' },
  { id: 4, icon: '🎁', label: '$10 Gift Card', desc: 'Digital gift card to BurgerCraft or Taco Verde', cost: 900, category: 'Gift Cards' },
  { id: 5, icon: '🕐', label: 'Pick Your Shift', desc: 'Choose your preferred shift for one week', cost: 1100, category: 'Schedule' },
  { id: 6, icon: '👕', label: 'Brand Merch', desc: 'OpsHub × BurgerCraft crew hoodie', cost: 1400, category: 'Merch' },
  { id: 7, icon: '🎟️', label: '$25 Gift Card', desc: 'Digital gift card — any brand', cost: 1800, category: 'Gift Cards' },
  { id: 8, icon: '🏖️', label: 'Extra Day Off', desc: 'One paid day off, manager-approved scheduling', cost: 2500, category: 'Schedule' },
]

export const LEADERBOARD = [
  { rank: 1, name: 'Jordan Lee', initials: 'JL', level: 6, xp: 2180, streak: 14, badge: '🥇' },
  { rank: 2, name: 'Sam Rivera', initials: 'SR', level: 4, xp: 1240, streak: 7, badge: '🥈', isMe: true },
  { rank: 3, name: 'Chris Patel', initials: 'CP', level: 4, xp: 1190, streak: 5, badge: '🥉' },
  { rank: 4, name: 'Dana Kim', initials: 'DK', level: 3, xp: 940, streak: 3, badge: null },
  { rank: 5, name: 'Alex Ruiz', initials: 'AR', level: 3, xp: 820, streak: 2, badge: null },
  { rank: 6, name: 'Morgan Chen', initials: 'MC', level: 2, xp: 560, streak: 0, badge: null },
]

export const ACHIEVEMENTS = [
  { id: 1, icon: '🧼', label: 'Food Safety Certified', desc: 'Completed Food Safety Fundamentals', earned: true },
  { id: 2, icon: '🔥', label: 'Opening Pro', desc: 'Completed all opening procedure training', earned: true },
  { id: 3, icon: '🌙', label: 'Closing Pro', desc: 'Completed all closing procedure training', earned: false },
  { id: 4, icon: '⭐', label: 'Brand Champion', desc: 'Completed all brand standards training', earned: false },
  { id: 5, icon: '🧯', label: 'Safety First', desc: 'Completed workplace safety training', earned: false },
  { id: 6, icon: '🏆', label: 'Operations Expert', desc: 'Completed all core operations training', earned: false },
  { id: 7, icon: '🎯', label: 'Perfect Score', desc: 'Earned 100% on multiple assessments', earned: false },
]

export const QUIZ_QUESTIONS = [
  {
    text: 'What is the minimum safe internal temperature for cooked ground beef?',
    options: ['145°F (63°C)', '155°F (68°C)', '165°F (74°C)', '135°F (57°C)'],
    correct: 1,
    explanation: 'Ground beef must reach 155°F (68°C) to destroy pathogens including E. coli O157:H7. Use a calibrated probe thermometer inserted to the thickest point.',
    xp: 30,
  },
  {
    text: 'How often should sanitizer solution in buckets be tested during a shift?',
    options: ['Once at opening', 'Every 4 hours', 'Every 2 hours', 'Only when visibly dirty'],
    correct: 2,
    explanation: 'Sanitizer concentration drops over time with use. Testing every 2 hours ensures it stays within the required 200–400 ppm range throughout service.',
    xp: 30,
  },
  {
    text: 'What does FIFO stand for in food storage?',
    options: ['First In, First Out', 'Fresh Items Fill Often', 'Food Inventory First Order', 'Frozen Items For Overnight'],
    correct: 0,
    explanation: 'FIFO (First In, First Out) means the oldest stock is used first. Rotate new deliveries to the back so older items get used before they expire.',
    xp: 20,
  },
  {
    text: 'Which temperature range is known as the "Danger Zone" for food safety?',
    options: ['32°F–70°F', '41°F–135°F', '50°F–145°F', '60°F–165°F'],
    correct: 1,
    explanation: 'The Danger Zone (41°F–135°F / 5°C–57°C) is where bacteria multiply most rapidly. Keep cold foods below 41°F and hot foods above 135°F.',
    xp: 25,
  },
  {
    text: 'How long can a prepared food item safely sit at room temperature?',
    options: ['4 hours', '2 hours', '6 hours', '1 hour'],
    correct: 1,
    explanation: 'The 2-hour rule: perishable foods should not sit in the Danger Zone for more than 2 hours total. Discard anything beyond that threshold.',
    xp: 25,
  },
]

export const CHALLENGE = {
  title: "Spot the Safety Risk",
  scenario: "You're doing your opening line check. Walk through this kitchen scene and tap every item that's a food safety violation.",
  items: [
    { id: 0, text: 'Walk-in cooler reads 38°F', violation: false, explanation: 'Safe — cold storage must be 41°F or below. 38°F is within spec.' },
    { id: 1, text: "Container of cooked beef labeled 'yesterday' — no temp noted", violation: true, explanation: 'Violation — unlabeled or undated food must be discarded. No temp record means no HACCP documentation.' },
    { id: 2, text: 'Sanitizer bucket tests at 150 ppm', violation: true, explanation: 'Violation — sanitizer must be 200–400 ppm. Below 200 ppm is ineffective against pathogens.' },
    { id: 3, text: 'Gloves stocked at every prep station', violation: false, explanation: 'Good practice — properly stocked PPE at every station is correct.' },
    { id: 4, text: 'Raw chicken stored on shelf above cut vegetables', violation: true, explanation: 'Violation — raw poultry must always be stored below ready-to-eat foods to prevent drip cross-contamination.' },
    { id: 5, text: 'Cutting board is deeply grooved and discolored', violation: true, explanation: 'Violation — deep grooves harbor bacteria that sanitizer cannot reach. Board must be replaced.' },
  ],
  xp: 80,
}

export type LeaderboardEntry = typeof LEADERBOARD[number]
export type Reward = typeof REWARDS[number]
