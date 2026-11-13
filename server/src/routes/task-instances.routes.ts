import { Router, type RequestHandler } from 'express';
import { type Pool } from 'pg';
import {
  createTaskCompleteController,
  createTaskReopenController
} from '../controller/task-instances.controller.js';

const requireJsonBody: RequestHandler = (req, res, next) => {
  const hasBody =
    req.headers['transfer-encoding'] !== undefined ||
    Number(req.headers['content-length'] ?? 0) > 0;

  if (hasBody && !req.is('application/json')) {
    res.status(415).json({
      error: {
        code: 'UNSUPPORTED_MEDIA_TYPE',
        message: 'Request bodies must use Content-Type: application/json.',
      },
    });
    return;
  }

  next();
};

export function createTaskInstancesRouter(deps: {
  pool: Pool;
  requireAuth: RequestHandler;
}) {
  const router = Router();

  const completeTask = createTaskCompleteController(deps.pool);
  const reopenTask = createTaskReopenController(deps.pool);

  router.post(
    '/:id/complete',
    deps.requireAuth,
    requireJsonBody,
    completeTask
  );
  router.post(
    '/:id/reopen',
    deps.requireAuth,
    requireJsonBody,
    reopenTask
  );

  return router;
}