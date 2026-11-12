import { createApp } from './app.js'
import { createAuthClient } from './auth/bearer-token.js';
import { createRequireAuth } from './auth/require-auth.js';
import { createDatabasePool } from './db/pool.js'

// Load .env if present (Node >= 20.12). Missing file is fine — defaults are used.
try {
  process.loadEnvFile()
} catch {
  /* no .env file */
}

const PORT = Number(process.env.PORT ?? 4000)
const pool = createDatabasePool();
const requireAuth = createRequireAuth(createAuthClient());

createApp({ pool, requireAuth }).listen(PORT, () => {
  console.log(`Tasks API running at http://localhost:${PORT}/api/tasks`)
})
