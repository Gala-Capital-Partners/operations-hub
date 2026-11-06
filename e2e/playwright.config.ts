import { defineConfig, devices } from '@playwright/test'

const CLIENT_URL = process.env.E2E_CLIENT_URL ?? 'http://localhost:3000'
const API_URL = process.env.E2E_API_URL ?? 'http://localhost:4000/api'

/**
 * Playwright starts the Express API and the Next.js client before the tests run
 * (or reuses them if you already have `npm run dev` going in both folders).
 *
 * Tests run one at a time because the API keeps tasks in memory: every test
 * resets that store first, so tests must not overlap.
 */
export default defineConfig({
  testDir: './tests',
  fullyParallel: false,
  workers: 1,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  timeout: 60_000,
  expect: { timeout: 10_000 },
  reporter: [['list'], ['html', { open: 'never' }]],

  use: {
    baseURL: CLIENT_URL,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },

  projects: [
    { name: 'desktop-chromium', use: { ...devices['Desktop Chrome'] } },
  ],

  webServer: [
    {
      command: 'npm run dev',
      cwd: '../server',
      url: `${API_URL}/health`,
      reuseExistingServer: !process.env.CI,
      timeout: 60_000,
      env: {
        PORT: '4000',
        CORS_ORIGIN: CLIENT_URL,
        // The server requires these at startup. The e2e tests only use the in-memory
        // /api/tasks routes, so placeholders are enough; nothing connects to them.
        DATABASE_URL: process.env.DATABASE_URL ?? 'postgresql://e2e:e2e@127.0.0.1:1/e2e',
        SUPABASE_URL: process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321',
        SUPABASE_PUBLISHABLE_KEY: process.env.SUPABASE_PUBLISHABLE_KEY ?? 'e2e-placeholder-key',
      },
    },
    {
      command: 'npm run dev',
      cwd: '../client',
      url: CLIENT_URL,
      reuseExistingServer: !process.env.CI,
      timeout: 180_000,
      env: { NEXT_PUBLIC_API_URL: API_URL, NEXT_TELEMETRY_DISABLED: '1' },
    },
  ],
})
