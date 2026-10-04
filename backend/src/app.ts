import cors from 'cors'
import express, { type NextFunction, type Request, type Response } from 'express'
import { tasksRouter } from './routes/tasks.routes.js'

export function createApp() {
  const app = express()

  const origins = (process.env.CORS_ORIGIN ?? 'http://localhost:3000')
    .split(',')
    .map(o => o.trim())
    .filter(Boolean)

  app.use(cors({ origin: origins }))
  app.use(express.json({ limit: '1mb' }))

  app.get('/api/health', (_req, res) => {
    res.json({ status: 'ok' })
  })

  app.use('/api/tasks', tasksRouter)

  // 404 for unknown routes
  app.use((req, res) => {
    res.status(404).json({ error: { message: `Route ${req.method} ${req.path} not found` } })
  })

  // Error handler (also catches malformed JSON bodies)
  app.use((err: Error & { status?: number; type?: string }, _req: Request, res: Response, _next: NextFunction) => {
    if (err.type === 'entity.parse.failed') {
      return res.status(400).json({ error: { message: 'Malformed JSON body' } })
    }
    console.error(err)
    res.status(err.status ?? 500).json({ error: { message: 'Internal server error' } })
  })

  return app
}
