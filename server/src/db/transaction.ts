import { Pool, PoolClient } from 'pg';

/**
 * Convenience wrapper for a single query.
 */
export function queryAsUser(pool: Pool, userId: string, query: string, values: unknown[] = []) {
  return withUserTransaction(pool, userId, (client) => client.query(query, values))
}

/**
 * Runs `work` inside one database transaction as the authenticated user.
 *
 * Every protected query must go through this function (or queryAsUser):
 * - SET LOCAL ROLE switches to operations_hub_runtime, which cannot bypass RLS.
 *   The backend login itself has no table privileges, so skipping this fails closed.
 * - app.user_id is set transaction-locally (third argument `true`), so it is cleared
 *   on COMMIT/ROLLBACK and cannot leak to the next request on a reused connection.
 * - All queries in `work` share one connection and one transaction, so they see
 *   the same identity and either all commit or all roll back.
 *
 * `userId` must come from a verified access token (res.locals.actorId),
 * never from the request body, query string, or headers.
 *
 * Do not call COMMIT, ROLLBACK, SET ROLE, or set_config inside `work`.
 */
export async function withUserTransaction<T>(
  pool: Pool,
  userId: string,
  work: (client: PoolClient) => Promise<T>,
): Promise<T> {
  const client = await pool.connect()
  let discard = false
  try {
    await client.query('BEGIN')
    await client.query("SET LOCAL ROLE operations_hub_runtime")
    await client.query("SELECT set_config('app.user_id', $1, true)", [userId])
    const result = await work(client)
    await client.query('COMMIT')
    return result
  } catch (err) {
    try { await client.query('ROLLBACK') } catch { discard = true }
    throw err
  } finally {
    client.release(discard)
  }
}