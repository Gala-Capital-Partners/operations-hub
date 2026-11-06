import { test as base, expect, type APIRequestContext, type Page } from '@playwright/test'

export const API_URL = process.env.E2E_API_URL ?? 'http://localhost:4000/api'

export type Role = 'corporate' | 'brand' | 'manager' | 'employee'
export type Brand = 'burgercraft' | 'tacoverde'

export const ROLE_LABELS: Record<Role, string> = {
  corporate: 'Corporate Admin',
  brand: 'Brand Admin',
  manager: 'Location Manager',
  employee: 'Employee',
}

type ConsoleProblem = { kind: 'console.error' | 'pageerror' | 'requestfailed'; text: string }

type Fixtures = {
  /** Console errors a test expects (e.g. when it deliberately breaks the API). Unset = allow none. */
  allowedConsoleErrors: RegExp | undefined
  /** Collected browser problems; checked automatically after every test. */
  consoleProblems: ConsoleProblem[]
  api: APIRequestContext
}

/**
 * Every test:
 *  1. resets the in-memory tasks API to its seed data, so tests are independent;
 *  2. records console errors, uncaught page exceptions and failed requests;
 *  3. fails if anything was recorded that the test did not explicitly allow ("zero console errors").
 */
export const test = base.extend<Fixtures>({
  allowedConsoleErrors: [undefined, { option: true }],

  api: async ({ playwright }, use) => {
    const ctx = await playwright.request.newContext({ baseURL: `${API_URL}/` })
    await use(ctx)
    await ctx.dispose()
  },

  consoleProblems: async ({}, use) => {
    await use([])
  },

  page: async ({ page, api, consoleProblems, allowedConsoleErrors }, use) => {
    const reset = await api.post('tasks/reset')
    expect(reset.ok(), 'POST /api/tasks/reset should succeed').toBeTruthy()

    page.on('console', msg => {
      if (msg.type() === 'error') consoleProblems.push({ kind: 'console.error', text: msg.text() })
    })
    page.on('pageerror', err => consoleProblems.push({ kind: 'pageerror', text: err.message }))
    page.on('requestfailed', req => {
      // Navigations cancelled by client-side redirects are normal, not failures.
      if (req.failure()?.errorText === 'net::ERR_ABORTED') return
      consoleProblems.push({ kind: 'requestfailed', text: `${req.method()} ${req.url()} — ${req.failure()?.errorText}` })
    })

    await use(page)

    const unexpected = consoleProblems.filter(p => !allowedConsoleErrors?.test(p.text))
    expect(unexpected, 'browser console errors / page exceptions / failed requests').toEqual([])
  },
})

export { expect }

/** Sign in through the real login screen with a given brand and preview role. */
export async function signIn(page: Page, role: Role, brand: Brand = 'burgercraft') {
  await page.goto('/')
  await expect(page.getByRole('heading', { name: 'Welcome back' })).toBeVisible()
  await page.getByRole('button', { name: brand === 'burgercraft' ? 'BC' : 'TV', exact: true }).click()
  await page.getByRole('combobox').selectOption(role)
  await page.getByRole('button', { name: 'Sign in to OpsHub' }).click()
  await expect(page).toHaveURL(/\/dashboard$/)
}

/** The app's error banner (excludes Next.js's hidden route announcer, which also has role="alert"). */
export function apiAlert(page: Page) {
  return page.locator('[role="alert"]:not(#__next-route-announcer__)')
}

/** The desktop sidebar (the mobile tab bar is hidden at desktop width). */
export function sidebar(page: Page) {
  return page.locator('aside nav')
}

/** Open a screen from the sidebar navigation. */
export async function navigateTo(page: Page, label: 'Dashboard' | 'Knowledge' | 'Tasks' | 'Training' | 'Compliance') {
  await sidebar(page).getByRole('link', { name: label }).click()
  await expect(page).toHaveURL(new RegExp(`/${label.toLowerCase()}$`))
}

/** A task row on the Tasks screen, found by its label text. */
export function taskRow(page: Page, label: string) {
  return page.locator('div.group', { has: page.getByText(label, { exact: true }) })
}

/** Read a task straight from the API to confirm what the UI did was persisted. */
export async function findTaskByLabel(api: APIRequestContext, label: string) {
  const res = await api.get('tasks')
  expect(res.ok()).toBeTruthy()
  const tasks = (await res.json()) as { id: number; label: string; done: boolean; cat: string }[]
  return tasks.find(t => t.label === label)
}
