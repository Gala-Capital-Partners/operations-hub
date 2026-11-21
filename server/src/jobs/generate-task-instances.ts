import { pathToFileURL } from 'node:url';
import { Pool, type PoolClient } from 'pg';
import {
  loadSchedulerGenerationDefinitions,
  generateRollingTaskInstances,
} from '../scheduling/generator.js';

type JobSummary = {
  processed: number;
  succeeded: number;
  skipped: number;
  inserted: number;
  failed: number;
};

type JobOptions = {
  now?: () => Date;
  logger?: Pick<Console, 'info' | 'warn' | 'error'>;
};

const MAX_ATTEMPTS = 3;
const NETWORK_CODES = new Set(['ECONNREFUSED', 'ETIMEDOUT', 'ECONNRESET', 'ENOTFOUND', 'EAI_AGAIN']);

// Never print raw database errors: they may contain connection details or data.
function errorCode(error: unknown): string {
  if (error instanceof RangeError) return 'INVALID_GENERATION_INPUT';
  if (
    typeof error === 'object' &&
    error !== null &&
    'code' in error &&
    typeof error.code === 'string' &&
    (error.code === 'CONFIG' || NETWORK_CODES.has(error.code) || /^[A-Z0-9]{5}$/.test(error.code))
  ) {
    return error.code;
  }
  return 'UNKNOWN';
}

function createSchedulerPool(): Pool {
  const connectionString = process.env.TASK_SCHEDULER_DATABASE_URL;
  if (!connectionString) {
    // The CLI prints a safe category rather than this underlying error.
    throw Object.assign(new Error('TASK_SCHEDULER_DATABASE_URL is required.'), {
      code: 'CONFIG',
    });
  }
  return new Pool({
    connectionString,
    max: 1,
    connectionTimeoutMillis: 10_000,
    statement_timeout: 60_000,
  });
}

async function withSchedulerTransaction<T>(
  pool: Pool,
  work: (db: PoolClient) => Promise<T>,
): Promise<T> {
  const db = await pool.connect();
  let discard = false;
  try {
    await db.query('BEGIN');
    await db.query('SET LOCAL ROLE operations_hub_scheduler');
    const result = await work(db);
    await db.query('COMMIT');
    return result;
  } catch (error) {
    try {
      await db.query('ROLLBACK');
    } catch {
      discard = true;
    }
    throw error;
  } finally {
    db.release(discard);
  }
}

/** Runs once. The caller owns the pool; importing this module does not start a job. */
export async function runGenerationJob(
  pool: Pool,
  { now = () => new Date(), logger = console }: JobOptions = {},
): Promise<JobSummary> {
  const definitions = await withSchedulerTransaction(
    pool,
    loadSchedulerGenerationDefinitions,
  );
  const summary: JobSummary = {
    processed: 0,
    succeeded: 0,
    skipped: 0,
    inserted: 0,
    failed: 0,
  };

  for (const initial of definitions) {
    summary.processed += 1;
    for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt += 1) {
      try {
        const count = await withSchedulerTransaction(pool, async (db) => {
          // A stale token must be replaced, not reused. Reload inside the new
          // transaction after rollback. No new SQL privileges are required.
          const definition =
            attempt === 1
              ? initial
              : (await loadSchedulerGenerationDefinitions(db)).find(
                  (item) => item.id === initial.id,
                );
          if (!definition) return null; // Removed/deactivated since the initial listing.
          // Zero catch-up explicitly: routine jobs must not invent historical misses.
          return generateRollingTaskInstances(
            db,
            definition,
            now(),
            'scheduler',
            0,
          );
        });
        if (count === null) {
          summary.skipped += 1;
        } else {
          summary.inserted += count;
          summary.succeeded += 1;
        }
        break;
      } catch (error) {
        const code = errorCode(error);
        if (code === '40001' && attempt < MAX_ATTEMPTS) {
          logger.warn(
            `Retrying task generation definition=${initial.id} attempt=${attempt} code=${code}`,
          );
          continue;
        }
        summary.failed += 1;
        logger.error(
          `Task generation failed definition=${initial.id} attempts=${attempt} code=${code}`,
        );
        break;
      }
    }
  }
  logger.info(`Task generation summary ${JSON.stringify(summary)}`);
  return summary;
}

/** CLI lifecycle; returning an exit code keeps tests independent of process state. */
export async function main(
  pool: Pool = createSchedulerPool(),
): Promise<number> {
  let connectionFailed = false;
  const onPoolError = (error: Error) => {
    connectionFailed = true;
    console.error(`Scheduler pool error code=${errorCode(error)}`);
  };
  pool.on('error', onPoolError);
  try {
    const summary = await runGenerationJob(pool);
    return summary.failed > 0 || connectionFailed ? 1 : 0;
  } finally {
    try {
      await pool.end();
    } finally {
      pool.off('error', onPoolError);
    }
  }
}

// Works for both the compiled ESM script and direct tsx execution.
if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  main()
    .then((code) => {
      process.exitCode = code;
    })
    .catch((error) => {
      console.error(`Task generation job failed code=${errorCode(error)}`);
      process.exitCode = 1;
    });
}
