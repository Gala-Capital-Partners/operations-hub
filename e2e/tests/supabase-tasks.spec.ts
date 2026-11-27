import { test, expect, sidebar } from './fixtures'
import type { Page } from '@playwright/test'

/**
 * Database-backed Tasks screen against a local Supabase loaded with supabase/seed.sql
 * and the /api/task-instances endpoints. Runs only with E2E_SUPABASE=1.
 * Tests that complete a task reopen it again as the location manager, so the seed
 * state is restored and the suite can be re-run without a database reset.
 */
const PASSWORD = 'opshub-local-dev'

async function signIn(page: Page, email: string) {
  await page.goto('/')
  await page.getByLabel('Email address').fill(email)
  await page.getByLabel('Password').fill(PASSWORD)
  await page.getByRole('button', { name: 'Sign in to OpsHub' }).click()
  await expect(page).toHaveURL(/\/dashboard$/)
}

async function openTasks(page: Page) {
  await sidebar(page).getByRole('link', { name: 'Tasks' }).click()
  await expect(page).toHaveURL(/\/tasks$/)
  await expect(page.getByText('Loading tasks…')).toHaveCount(0)
}

async function signOut(page: Page) {
  await page.locator('aside').getByRole('button', { name: 'Sign out' }).click()
  await expect(page).toHaveURL(/\/$/)
}

const progress = (page: Page) => page.getByTestId('task-progress')
/** A task row in today's category sections (not the "still open from yesterday" list). */
const todayRow = (page: Page, name: string) =>
  page.locator('div.bg-white:not(.border-red-200) [data-task-id]', { has: page.getByText(name, { exact: true }) })
const dialog = (page: Page) => page.getByRole('dialog')

async function counts(page: Page) {
  const [done, total] = (await progress(page).innerText()).split('/').map(Number)
  return { done, total }
}

test.describe('Database tasks (Supabase)', () => {
  test('an employee sees today’s tasks for their location, grouped by shift', async ({ page }) => {
    await signIn(page, 'sam.rivera@opshub.test')
    await openTasks(page)
    await expect(page.getByText('Downtown Flagship · BC-001')).toBeVisible()
    await expect(page.getByRole('button', { name: 'Add Task' })).toHaveCount(0)
    await expect(page.getByRole('combobox')).toHaveCount(0) // one location: no picker
    for (const section of ['Opening', 'Midday', 'Closing']) {
      await expect(page.getByText(section, { exact: true }).first()).toBeVisible()
    }
    // Timed task: two occurrences shown at their local times.
    await expect(todayRow(page, 'Hot-holding temperature check')).toHaveCount(2)
    await expect(todayRow(page, 'Hot-holding temperature check').nth(0)).toContainText('11:00 AM')
    await expect(todayRow(page, 'Hot-holding temperature check').nth(1)).toContainText('3:00 PM')
    const { total } = await counts(page)
    expect(total).toBeGreaterThan(0)
  })

  test('an employee completes a task; a manager can reopen it', async ({ page }) => {
    const name = 'Review prep levels with kitchen lead'
    await signIn(page, 'sam.rivera@opshub.test')
    await openTasks(page)
    const before = await counts(page)

    await todayRow(page, name).getByRole('button', { name: 'Mark complete' }).click()
    await expect(progress(page)).toHaveText(`${before.done + 1}/${before.total}`)

    await page.reload()
    await expect(progress(page)).toHaveText(`${before.done + 1}/${before.total}`)
    // Employees can't reopen: the checkbox is disabled and the dialog says why.
    await expect(todayRow(page, name).getByRole('button', { name: 'Reopen task' })).toBeDisabled()
    await todayRow(page, name).getByText(name).click()
    await expect(dialog(page)).toContainText('Completed by you')
    await expect(dialog(page)).toContainText('Only a location manager can reopen')
    await dialog(page).getByRole('button', { name: 'Close' }).click()
    await signOut(page)

    await signIn(page, 'jordan.lee@opshub.test')
    await openTasks(page)
    await todayRow(page, name).getByRole('button', { name: 'Reopen task' }).click()
    await expect(progress(page)).toHaveText(`${before.done}/${before.total}`)
    await page.reload()
    await expect(progress(page)).toHaveText(`${before.done}/${before.total}`)
  })

  test('a reading is checked against its bounds and saved with notes', async ({ page }) => {
    await signIn(page, 'sam.rivera@opshub.test')
    await openTasks(page)
    const before = await counts(page)
    const first = todayRow(page, 'Hot-holding temperature check').first()

    await first.getByRole('button', { name: 'Mark complete' }).click() // numeric tasks open the dialog
    await dialog(page).getByLabel(/Reading/).fill('300')
    await dialog(page).getByRole('button', { name: 'Mark complete' }).click()
    await expect(dialog(page).getByRole('alert')).toHaveText('Must be at most 250.')

    await dialog(page).getByLabel(/Reading/).fill('165')
    await dialog(page).getByLabel(/Notes/).fill('Probed the burger patties.')
    await dialog(page).getByRole('button', { name: 'Mark complete' }).click()
    await expect(dialog(page)).toHaveCount(0)
    await expect(progress(page)).toHaveText(`${before.done + 1}/${before.total}`)
    await expect(first).toContainText('165 °F')

    await page.reload()
    await todayRow(page, 'Hot-holding temperature check').first().getByText('Hot-holding temperature check').click()
    await expect(dialog(page)).toContainText('Reading: 165 °F')
    await expect(dialog(page)).toContainText('Probed the burger patties.')
    await dialog(page).getByRole('button', { name: 'Close' }).click()
    await signOut(page)

    // Clean up as the manager.
    await signIn(page, 'jordan.lee@opshub.test')
    await openTasks(page)
    await todayRow(page, 'Hot-holding temperature check').first().getByText('Hot-holding temperature check').click()
    await dialog(page).getByRole('button', { name: 'Reopen task' }).click()
    await expect(dialog(page)).toHaveCount(0)
    await expect(progress(page)).toHaveText(`${before.done}/${before.total}`)
  })

  test('past days can be browsed and show completed history', async ({ page }) => {
    await signIn(page, 'jordan.lee@opshub.test')
    await openTasks(page)
    const todayLabel = await page.getByTestId('task-date').innerText()
    await page.getByRole('button', { name: 'Previous day' }).click()
    await expect(page.getByTestId('task-date')).not.toHaveText(todayLabel)
    await expect(page.getByText('Tasks complete', { exact: true })).toBeVisible()
    const { done } = await counts(page)
    expect(done).toBeGreaterThan(0)
    await page.getByRole('button', { name: 'Today' }).click()
    await expect(page.getByTestId('task-date')).toHaveText(todayLabel)
  })

  test('a brand admin can browse every brand location read-only, with a rollup', async ({ page }) => {
    await signIn(page, 'maria.santos@opshub.test')
    await openTasks(page)
    await expect(page.getByText('View only: tasks are completed by the team at each location.')).toBeVisible()
    await expect(page.getByRole('combobox')).toHaveCount(1)
    await expect(page.getByRole('combobox').locator('option')).toHaveCount(4)
    const checkbox = page.locator('[data-task-id] button').first()
    await expect(checkbox).toBeDisabled()

    await page.getByRole('button', { name: 'All Locations' }).click()
    await expect(page.getByRole('heading', { name: 'All Locations — Today' })).toBeVisible()
    await expect(page.getByTestId('rollup-row')).toHaveCount(4)
    await page.getByTestId('rollup-row').filter({ hasText: 'Airport Terminal B' }).click()
    await expect(page.getByText('Airport Terminal B · BC-003')).toBeVisible()
  })

  test('a Taco Verde manager only sees Taco Verde tasks', async ({ page }) => {
    await signIn(page, 'taylor.kim@opshub.test')
    await openTasks(page)
    await expect(page.getByText('Harbor View · TV-002')).toBeVisible()
    await expect(page.getByText('Prep salsa bar and check date labels').first()).toBeVisible()
    await expect(page.getByText('Review prep levels with kitchen lead')).toHaveCount(0)
  })
})

test('a manager can cancel confirmation and then deactivate the definition behind a checklist item', async ({ page }) => {
  const definitionId = 'f1c476e0-edf6-4a29-83ac-f9c34ab0c541'
  const name = 'Review prep levels with kitchen lead'
  const brandTask = 'Brand-wide opening checklist'
  // Sign-in lands on the dashboard before the checklist.
  await page.route('**/api/task-instances/summary?**', route => route.fulfill({ json: {
    date: new URL(route.request().url()).searchParams.get('date'),
    totals: { locations: 0, locationsWithoutTasks: 0, total: 0, completed: 0, remaining: 0 },
    locations: [],
  } }))
  let posts = 0
  // Keep the seed intact. The SQL suite exercises how the API computes these flags.
  await page.route('**/api/task-instances?**', async route => {
    const occurrence = {
      id: 'store-occurrence', definitionId, name, category: 'Opening', isAllDay: true,
      scheduledDay: new URL(route.request().url()).searchParams.get('date'),
      completedAt: null, completedBy: null, numericUnit: null, notes: null,
      dueTime: null, timezone: 'America/Los_Angeles',
    }
    await route.fulfill({ json: { tasks: [
      { ...occurrence, canDeactivate: posts === 0 },
      { ...occurrence, id: 'brand-occurrence', definitionId: 'brand-definition', name: brandTask, canDeactivate: false },
    ] } })
  })
  await page.route(`**/api/task-definitions/${definitionId}/deactivate`, async route => {
    expect(route.request().method()).toBe('POST')
    expect(route.request().headers().authorization).toMatch(/^Bearer /)
    posts++
    await route.fulfill({ json: { id: definitionId, isActive: false, cancelledInstanceCount: 3 } })
  })
  await signIn(page, 'jordan.lee@opshub.test')
  await openTasks(page)
  await todayRow(page, brandTask).getByText(brandTask).click()
  await expect(dialog(page).getByRole('button', { name: 'Deactivate task definition' })).toHaveCount(0)
  await dialog(page).getByRole('button', { name: 'Close' }).click()
  await todayRow(page, name).getByText(name).click()
  const action = dialog(page).getByRole('button', { name: 'Deactivate task definition' })
  page.once('dialog', prompt => prompt.dismiss())
  await action.click()
  expect(posts).toBe(0)
  page.once('dialog', prompt => prompt.accept())
  await action.click()
  await expect(page.getByText('Definition inactive. 3 future open occurrences cancelled.')).toBeVisible()
  expect(posts).toBe(1)
  await page.reload()
  await todayRow(page, name).getByText(name).click()
  await expect(action).toHaveCount(0)
})
