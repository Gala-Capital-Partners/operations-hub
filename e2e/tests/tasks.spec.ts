import { test, expect, signIn, navigateTo, taskRow, findTaskByLabel, apiAlert } from './fixtures'

// Seed data (server/src/data/tasks.seed.ts): 7 tasks due on the demo "today" (2 already done)
// plus 2 overdue tasks from earlier dates.
const SEED_TODAY_TOTAL = 7
const SEED_TODAY_DONE = 2

/** The open New/Edit task dialog. */
function modal(page: import('@playwright/test').Page) {
  return page.locator('div.fixed.inset-0.z-50')
}

function progress(page: import('@playwright/test').Page) {
  return page.getByText('Tasks complete today').locator('xpath=preceding-sibling::p[1]')
}

test.describe('Daily checklist (manager)', () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page, 'manager')
    await navigateTo(page, 'Tasks')
    await expect(page.getByText('Loading tasks…')).toHaveCount(0)
  })

  test('shows tasks from the API grouped by shift, with progress and overdue items', async ({ page }) => {
    await expect(progress(page)).toHaveText(`${SEED_TODAY_DONE}/${SEED_TODAY_TOTAL}`)
    for (const section of ['Opening', 'Midday', 'Closing']) {
      await expect(page.getByText(section, { exact: true }).first()).toBeVisible()
    }
    await expect(page.getByText('Overdue', { exact: true })).toBeVisible()
    await expect(page.getByText('2 tasks', { exact: true })).toBeVisible()
    await expect(taskRow(page, 'Review prep levels with kitchen lead')).toBeVisible()
    await expect(taskRow(page, 'Log fridge temperatures — morning check')).toContainText('Due 2026-08-16')
  })

  test('completing a task updates progress and is saved to the API', async ({ page, api }) => {
    const label = 'Review prep levels with kitchen lead'
    await taskRow(page, label).getByRole('button', { name: 'Mark complete' }).click()

    await expect(progress(page)).toHaveText(`${SEED_TODAY_DONE + 1}/${SEED_TODAY_TOTAL}`)
    await expect(taskRow(page, label).getByRole('button', { name: 'Mark incomplete' })).toBeVisible()
    await expect.poll(async () => (await findTaskByLabel(api, label))?.done).toBe(true)

    await page.reload()
    await expect(progress(page)).toHaveText(`${SEED_TODAY_DONE + 1}/${SEED_TODAY_TOTAL}`)
  })

  test('un-completing a task reverts it', async ({ page, api }) => {
    const label = 'Temperature log — walk-in cooler' // seeded as done
    await taskRow(page, label).getByRole('button', { name: 'Mark incomplete' }).click()
    await expect(progress(page)).toHaveText(`${SEED_TODAY_DONE - 1}/${SEED_TODAY_TOTAL}`)
    await expect.poll(async () => (await findTaskByLabel(api, label))?.done).toBe(false)
  })

  test('completing an overdue task removes it from the Overdue list', async ({ page, api }) => {
    const label = 'Submit produce order for next week'
    await taskRow(page, label).getByRole('button', { name: 'Mark complete' }).click()
    await expect(page.getByText('1 task', { exact: true })).toBeVisible()
    await expect(page.getByText(label, { exact: true })).toHaveCount(0)
    await expect.poll(async () => (await findTaskByLabel(api, label))?.done).toBe(true)
  })

  test('creating a task adds it to the checklist and persists it', async ({ page, api }) => {
    const label = `E2E new task ${Date.now()}`
    await page.getByRole('button', { name: 'Add Task' }).click()
    await expect(page.getByRole('heading', { name: 'New Task' })).toBeVisible()

    await page.getByPlaceholder('e.g. Check sanitizer concentration at all stations').fill(label)
    await modal(page).getByRole('button', { name: 'Closing', exact: true }).click()
    await modal(page).getByRole('button', { name: 'Add Task' }).click()

    await expect(page.getByRole('heading', { name: 'New Task' })).toHaveCount(0)
    await expect(taskRow(page, label)).toBeVisible()
    await expect(progress(page)).toHaveText(`${SEED_TODAY_DONE}/${SEED_TODAY_TOTAL + 1}`)

    await expect.poll(async () => (await findTaskByLabel(api, label))?.cat).toBe('Closing')
    await page.reload()
    await expect(taskRow(page, label)).toBeVisible()
  })

  test('a task cannot be created without a description, and Cancel discards the form', async ({ page, api }) => {
    await page.getByRole('button', { name: 'Add Task' }).click()
    const submit = modal(page).getByRole('button', { name: 'Add Task' })
    await expect(submit).toBeDisabled()

    await page.getByPlaceholder('e.g. Check sanitizer concentration at all stations').fill('   ')
    await expect(submit).toBeDisabled()

    await page.getByPlaceholder('e.g. Check sanitizer concentration at all stations').fill('Should not be saved')
    await modal(page).getByRole('button', { name: 'Cancel' }).click()
    await expect(page.getByRole('heading', { name: 'New Task' })).toHaveCount(0)
    expect(await findTaskByLabel(api, 'Should not be saved')).toBeUndefined()
  })

  test('editing a task saves the new description', async ({ page, api }) => {
    const before = 'Deposit preparation and safe count'
    const after = 'Deposit preparation, safe count and manager sign-off'

    await taskRow(page, before).getByText(before).click()
    await expect(page.getByRole('heading', { name: 'Edit Task' })).toBeVisible()
    const description = page.getByPlaceholder('e.g. Check sanitizer concentration at all stations')
    await expect(description).toHaveValue(before)
    await description.fill(after)
    await modal(page).getByRole('button', { name: 'Save Changes' }).click()

    await expect(taskRow(page, after)).toBeVisible()
    await expect(page.getByText(before, { exact: true })).toHaveCount(0)
    await expect.poll(async () => (await findTaskByLabel(api, after)) !== undefined).toBe(true)
    expect(await findTaskByLabel(api, before)).toBeUndefined()
  })

  test('deleting a task removes it from the checklist and the API', async ({ page, api }) => {
    const label = 'End-of-day cleaning checklist'
    await taskRow(page, label).getByText(label).click()
    await modal(page).getByRole('button', { name: 'Delete Task' }).click()

    await expect(page.getByText(label, { exact: true })).toHaveCount(0)
    await expect(progress(page)).toHaveText(`${SEED_TODAY_DONE}/${SEED_TODAY_TOTAL - 1}`)
    await expect.poll(async () => await findTaskByLabel(api, label)).toBeUndefined()

    await page.reload()
    await expect(page.getByText(label, { exact: true })).toHaveCount(0)
  })

  test('the All Locations rollup lists every location', async ({ page }) => {
    await page.getByRole('button', { name: 'All Locations' }).click()
    await expect(page.getByRole('heading', { name: 'All Locations — Today' })).toBeVisible()
    await expect(page.getByText(/\d+\/\d+ fully complete/)).toBeVisible()
    await page.getByRole('button', { name: 'My Tasks' }).click()
    await expect(page.getByText('Tasks complete today')).toBeVisible()
  })
})

test.describe('Daily checklist (employee)', () => {
  test('employees can complete tasks but cannot add, edit or delete them', async ({ page, api }) => {
    await signIn(page, 'employee')
    await navigateTo(page, 'Tasks')

    await expect(page.getByRole('button', { name: 'Add Task' })).toHaveCount(0)
    await expect(page.getByRole('button', { name: 'All Locations' })).toHaveCount(0)

    const label = 'Conduct line check before lunch service'
    await taskRow(page, label).getByText(label).click()
    await expect(page.getByRole('heading', { name: 'Edit Task' })).toHaveCount(0)

    await taskRow(page, label).getByRole('button', { name: 'Mark complete' }).click()
    await expect.poll(async () => (await findTaskByLabel(api, label))?.done).toBe(true)
  })
})

test.describe('API failure handling', () => {
  // These tests break the API on purpose, so the browser's own "failed request" logs are expected.
  test.use({ allowedConsoleErrors: /Failed to load resource|\/api\/tasks/ })

  test('shows an error with Retry when the API is unreachable, then recovers', async ({ page }) => {
    await signIn(page, 'manager')
    await page.route('**/api/tasks**', route => route.abort())
    await navigateTo(page, 'Tasks')

    const alert = apiAlert(page)
    await expect(alert).toContainText('Cannot reach the API')

    await page.unroute('**/api/tasks**')
    await alert.getByRole('button', { name: 'Retry' }).click()
    await expect(apiAlert(page)).toHaveCount(0)
    await expect(progress(page)).toHaveText(`${SEED_TODAY_DONE}/${SEED_TODAY_TOTAL}`)
  })

  test('rolls back an optimistic update when the API rejects it', async ({ page, api }) => {
    await signIn(page, 'manager')
    await navigateTo(page, 'Tasks')
    await expect(progress(page)).toHaveText(`${SEED_TODAY_DONE}/${SEED_TODAY_TOTAL}`)

    await page.route('**/api/tasks/*', route =>
      route.request().method() === 'PATCH'
        ? route.fulfill({ status: 500, contentType: 'application/json', body: JSON.stringify({ error: { message: 'Simulated server error' } }) })
        : route.continue(),
    )

    const label = 'Review prep levels with kitchen lead'
    await taskRow(page, label).getByRole('button', { name: 'Mark complete' }).click()

    await expect(apiAlert(page)).toContainText('Simulated server error')
    await expect(progress(page)).toHaveText(`${SEED_TODAY_DONE}/${SEED_TODAY_TOTAL}`)
    await expect(taskRow(page, label).getByRole('button', { name: 'Mark complete' })).toBeVisible()
    expect((await findTaskByLabel(api, label))?.done).toBe(false)
  })
})
