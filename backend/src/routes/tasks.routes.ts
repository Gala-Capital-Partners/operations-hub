import { Router, type Request, type Response } from 'express'
import * as store from '../store/task.store.js'
import { TASK_CATEGORIES, type TaskCategory } from '../types/task.js'
import { validateCreate, validateUpdate } from '../validation/task.js'

export const tasksRouter = Router()

function sendError(res: Response, status: number, message: string, details?: string[]) {
  res.status(status).json({ error: { message, ...(details ? { details } : {}) } })
}

function parseId(req: Request, res: Response): number | null {
  const id = Number(req.params.id)
  if (!Number.isInteger(id) || id <= 0) {
    sendError(res, 400, 'id must be a positive integer')
    return null
  }
  return id
}

/**
 * GET /api/tasks
 * Optional query: date, from, to (YYYY-MM-DD), cat (Opening|Midday|Closing), done (true|false)
 */
tasksRouter.get('/', (req, res) => {
  const { date, from, to, cat, done } = req.query
  const filter: store.TaskFilter = {}
  if (typeof date === 'string') filter.date = date
  if (typeof from === 'string') filter.from = from
  if (typeof to === 'string') filter.to = to
  if (typeof cat === 'string') {
    if (!TASK_CATEGORIES.includes(cat as TaskCategory))
      return sendError(res, 400, `cat must be one of: ${TASK_CATEGORIES.join(', ')}`)
    filter.cat = cat as TaskCategory
  }
  if (done === 'true' || done === 'false') filter.done = done === 'true'
  res.json(store.listTasks(filter))
})

/** GET /api/tasks/:id */
tasksRouter.get('/:id', (req, res) => {
  const id = parseId(req, res)
  if (id === null) return
  const task = store.getTask(id)
  if (!task) return sendError(res, 404, `Task ${id} not found`)
  res.json(task)
})

/** POST /api/tasks — create a task. Required: label, cat, date */
tasksRouter.post('/', (req, res) => {
  const result = validateCreate(req.body)
  if (!result.ok) return sendError(res, 400, 'Invalid task', result.errors)
  res.status(201).json(store.createTask(result.value))
})

/** PATCH /api/tasks/:id — partial update (e.g. { "done": true }) */
tasksRouter.patch('/:id', (req, res) => {
  const id = parseId(req, res)
  if (id === null) return
  const result = validateUpdate(req.body)
  if (!result.ok) return sendError(res, 400, 'Invalid task update', result.errors)
  const task = store.updateTask(id, result.value)
  if (!task) return sendError(res, 404, `Task ${id} not found`)
  res.json(task)
})

/** DELETE /api/tasks/:id */
tasksRouter.delete('/:id', (req, res) => {
  const id = parseId(req, res)
  if (id === null) return
  if (!store.deleteTask(id)) return sendError(res, 404, `Task ${id} not found`)
  res.status(204).end()
})

/** POST /api/tasks/reset — restore the mock data (demo helper) */
tasksRouter.post('/reset', (_req, res) => {
  store.resetTasks()
  res.json(store.listTasks())
})
