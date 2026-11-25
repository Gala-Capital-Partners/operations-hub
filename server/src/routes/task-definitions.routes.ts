import { Router, type RequestHandler } from 'express';
import { type Pool } from 'pg';
import {
  createTaskDefinitionController,
  createTaskDefinitionDeactivateController,
} from '../controller/task-definitions.controller.js';

// Bodies are optional for deactivation; when present they must be JSON.
const requireJsonIfBody: RequestHandler = (req, res, next) => {
  const hasBody =
    req.headers['transfer-encoding'] !== undefined ||
    Number(req.headers['content-length'] ?? 0) > 0;
  if (hasBody && !req.is('application/json')) {
    return res.status(415).json({
      error: {
        code: 'UNSUPPORTED_MEDIA_TYPE',
        message: 'Request bodies must use Content-Type: application/json.',
      },
    });
  }
  next();
};

export function createTaskDefinitionRouter(
  deps: { pool: Pool; requireAuth: RequestHandler }
) {
  const router = Router();
  const createTaskDefinition = createTaskDefinitionController(deps.pool);
  const deactivateTaskDefinition = createTaskDefinitionDeactivateController(deps.pool);
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
  router.post(
    '/:id/deactivate',
    deps.requireAuth,
    requireJsonIfBody,
    deactivateTaskDefinition,
  );
  return router;
}
