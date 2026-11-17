import { Router, type RequestHandler } from 'express';
import { type Pool } from 'pg';
import { createTaskDefinitionController } from '../controller/task-definitions.controller.js';

export function createTaskDefinitionRouter(
  deps: { pool: Pool; requireAuth: RequestHandler }
) {
  const router = Router();
  const createTaskDefinition = createTaskDefinitionController(deps.pool);
  // requireAuth verifies the access token and sets res.locals.actorId.
  router.post('/', deps.requireAuth, (req, res, next) => {
    if (!req.is('application/json')) {
      return res.status(415).json({
        error: {
          code: 'UNSUPPORTED_MEDIA_TYPE',
          message: 'Task creation requires Content-Type: application/json.',
        },
      });
    }
    next();
  }, createTaskDefinition);
  return router;
}
