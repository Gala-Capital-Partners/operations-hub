import { test, expect, sidebar, API_URL } from './fixtures'
import type { Page } from '@playwright/test'

/**
 * Real sign-in against a local Supabase loaded with supabase/seed.sql.
 * Runs only with E2E_SUPABASE=1 (see playwright.config.ts and README.md).
 */
const PASSWORD = 'opshub-local-dev'

async function signInWithPassword(page: Page, email: string, password = PASSWORD) {
  await page.goto('/')
  await expect(page.getByRole('heading', { name: 'Welcome back' })).toBeVisible()
  await page.getByLabel('Email address').fill(email)
  await page.getByLabel('Password').fill(password)
  await page.getByRole('button', { name: 'Sign in to OpsHub' }).click()
}

function account(page: Page) {
  return page.locator('aside')
}

test.describe('Real sign-in (Supabase)', () => {
  test('the login screen asks for email and password instead of a preview role', async ({ page }) => {
    await page.goto('/')
    await expect(page.getByLabel('Email address')).toBeVisible()
    await expect(page.getByLabel('Password')).toBeVisible()
    await expect(page.getByRole('combobox')).toHaveCount(0)
  })

  test.describe('rejected credentials', () => {
    // Supabase Auth answers a wrong password with HTTP 400, which the browser logs.
    test.use({ allowedConsoleErrors: /Failed to load resource|\/auth\/v1\/token/ })

    test('a wrong password shows an error and stays on the sign-in screen', async ({ page }) => {
      await signInWithPassword(page, 'sam.rivera@opshub.test', 'not-the-password')
      await expect(page.locator('[role="alert"]:not(#__next-route-announcer__)')).toHaveText('Incorrect email or password.')
      await expect(page).toHaveURL(/\/$/)
    })
  })

  test('an employee gets their own name, role, brand and single location', async ({ page }) => {
    await signInWithPassword(page, 'sam.rivera@opshub.test')
    await expect(page).toHaveURL(/\/dashboard$/)
    await expect(account(page).getByText('Sam Rivera', { exact: true })).toBeVisible()
    await expect(account(page).locator('p').getByText('Employee', { exact: true })).toBeVisible()
    await expect(account(page).getByText('BurgerCraft', { exact: true })).toBeVisible()
    await expect(account(page).getByText('OpsHub · 1 location')).toBeVisible()
    // Roles come from the database: no demo role switcher, no admin-only screens.
    await expect(page.getByText('Demo: Switch Role')).toHaveCount(0)
    await expect(sidebar(page).getByRole('link', { name: 'Compliance' })).toHaveCount(0)
  })

  test('a brand admin sees only their brand and its four locations', async ({ page }) => {
    await signInWithPassword(page, 'maria.santos@opshub.test')
    await expect(account(page).locator('p').getByText('Brand Admin', { exact: true })).toBeVisible()
    await expect(account(page).getByText('OpsHub · 4 locations')).toBeVisible()
    await expect(sidebar(page).getByRole('link', { name: 'Compliance' })).toBeVisible()
    await expect(account(page).getByRole('button', { name: 'TV', exact: true })).toHaveCount(0)
  })

  test('an organization admin can switch between both brands', async ({ page }) => {
    await signInWithPassword(page, 'alex.chen@opshub.test')
    await expect(account(page).locator('p').getByText('Corporate Admin', { exact: true })).toBeVisible()
    await expect(account(page).getByText('OpsHub · 4 locations')).toBeVisible()
    await account(page).getByRole('button', { name: 'TV', exact: true }).click()
    await expect(account(page).getByText('Taco Verde', { exact: true })).toBeVisible()
    await expect(account(page).getByText('OpsHub · 3 locations')).toBeVisible()
  })

  test("a Taco Verde manager lands in Taco Verde even if BurgerCraft was chosen on the login screen", async ({ page }) => {
    await signInWithPassword(page, 'taylor.kim@opshub.test')
    await expect(account(page).getByText('Taco Verde', { exact: true })).toBeVisible()
    await expect(account(page).getByText('Taylor Kim', { exact: true })).toBeVisible()
    await expect(page.getByRole('heading', { name: 'Good morning, Taylor' })).toBeVisible()
    await expect(account(page).getByText('OpsHub · 1 location')).toBeVisible()
  })

  test('the session survives a reload, and sign out ends it', async ({ page }) => {
    await signInWithPassword(page, 'jordan.lee@opshub.test')
    await expect(page).toHaveURL(/\/dashboard$/)
    await page.reload()
    await expect(account(page).getByText('Jordan Lee', { exact: true })).toBeVisible()

    await account(page).getByRole('button', { name: 'Sign out' }).click()
    await expect(page).toHaveURL(/\/$/)
    await page.goto('/dashboard')
    await expect(page).toHaveURL(/\/$/)
    const authKeys = await page.evaluate(() => Object.keys(localStorage).filter(k => k.startsWith('sb-')))
    expect(authKeys).toEqual([])
  })

  test('the API rejects /api/me without an access token', async ({ api }) => {
    const res = await api.get(`${API_URL}/me`)
    expect(res.status()).toBe(401)
  })
})
