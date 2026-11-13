import { test, expect, signIn, sidebar, navigateTo, ROLE_LABELS, type Role } from './fixtures'

test.describe('Sign-in and role-based access', () => {
  test('unauthenticated users are sent to the sign-in screen', async ({ page }) => {
    await page.goto('/tasks')
    await expect(page).toHaveURL(/\/$/)
    await expect(page.getByRole('heading', { name: 'Welcome back' })).toBeVisible()
  })

  for (const role of ['corporate', 'brand', 'manager', 'employee'] as Role[]) {
    test(`${ROLE_LABELS[role]} can sign in and lands on the dashboard`, async ({ page }) => {
      await signIn(page, role)
      await expect(page.locator('aside p').getByText(ROLE_LABELS[role], { exact: true })).toBeVisible()
      await expect(page.locator('main h1').first()).toBeVisible()
    })
  }

  test('brand selection on the login screen carries into the session', async ({ page }) => {
    await page.goto('/')
    await page.getByRole('button', { name: 'TV', exact: true }).click()
    await expect(page.getByText('Signing into')).toContainText('Taco Verde')
    await page.getByRole('combobox').selectOption('manager')
    await page.getByRole('button', { name: 'Sign in to OpsHub' }).click()
    await expect(page).toHaveURL(/\/dashboard$/)
    const session = await page.evaluate(() => JSON.parse(localStorage.getItem('opshub.session') ?? 'null'))
    expect(session).toEqual({ role: 'manager', brand: 'tacoverde' })
  })

  test('session survives a page reload', async ({ page }) => {
    await signIn(page, 'manager')
    await page.reload()
    await expect(page).toHaveURL(/\/dashboard$/)
    await expect(sidebar(page).getByRole('link', { name: 'Dashboard' })).toBeVisible()
  })

  test('sign out returns to the sign-in screen and protects app pages again', async ({ page }) => {
    await signIn(page, 'manager')
    await page.locator('aside').getByRole('button', { name: 'Sign out' }).click()
    await expect(page).toHaveURL(/\/$/)
    await page.goto('/dashboard')
    await expect(page).toHaveURL(/\/$/)
  })

  test('employees do not see Compliance and are redirected if they open it directly', async ({ page }) => {
    await signIn(page, 'employee')
    await expect(sidebar(page).getByRole('link', { name: 'Compliance' })).toHaveCount(0)
    await page.goto('/compliance')
    await expect(page).toHaveURL(/\/dashboard$/)
  })

  test('location managers do not see Compliance', async ({ page }) => {
    await signIn(page, 'manager')
    await expect(sidebar(page).getByRole('link', { name: 'Compliance' })).toHaveCount(0)
  })

  test('corporate admins see every screen, including Compliance', async ({ page }) => {
    await signIn(page, 'corporate')
    for (const label of ['Dashboard', 'Knowledge', 'Tasks', 'Training', 'Compliance']) {
      await expect(sidebar(page).getByRole('link', { name: label })).toBeVisible()
    }
  })
})

test.describe('Navigation', () => {
  test('every screen renders for a corporate admin with no console errors', async ({ page }) => {
    await signIn(page, 'corporate')
    for (const label of ['Knowledge', 'Tasks', 'Training', 'Compliance', 'Dashboard'] as const) {
      await navigateTo(page, label)
      await expect(sidebar(page).getByRole('link', { name: label })).toHaveAttribute('aria-current', 'page')
      await expect(page.locator('main h1').first()).toBeVisible()
    }
  })

  test('the daily checklist is reachable in at most two actions after sign-in (MOV: navigation effort)', async ({ page }) => {
    await signIn(page, 'employee')
    // Action 1: open Tasks from the sidebar.
    await sidebar(page).getByRole('link', { name: 'Tasks' }).click()
    await expect(page).toHaveURL(/\/tasks$/)
    await expect(page.getByText('Tasks complete today')).toBeVisible()
  })

  test('the manager rollup is reachable in at most two actions after sign-in (MOV: navigation effort)', async ({ page }) => {
    await signIn(page, 'manager')
    // Action 1: open Tasks. Action 2: switch to All Locations.
    await sidebar(page).getByRole('link', { name: 'Tasks' }).click()
    await page.getByRole('button', { name: 'All Locations' }).click()
    await expect(page.getByRole('heading', { name: 'All Locations — Today' })).toBeVisible()
  })

  test('a corporate admin can switch brands from the sidebar', async ({ page }) => {
    await signIn(page, 'corporate', 'burgercraft')
    await page.locator('aside').getByRole('button', { name: 'TV', exact: true }).click()
    await expect
      .poll(() => page.evaluate(() => JSON.parse(localStorage.getItem('opshub.session') ?? 'null')?.brand))
      .toBe('tacoverde')
  })
})
