import { createApp } from './app.js'

// Load .env if present (Node >= 20.12). Missing file is fine — defaults are used.
try {
  process.loadEnvFile()
} catch {
  /* no .env file */
}

const PORT = Number(process.env.PORT ?? 4000)

createApp().listen(PORT, () => {
  console.log(`Tasks API running at http://localhost:${PORT}/api/tasks`)
})
