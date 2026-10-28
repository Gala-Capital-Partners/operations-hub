import { Pool, PoolClient } from 'pg';

export async function transactionHelper(
  pool: Pool,
  query: string,
  userId: string,
  values: unknown[] = []
) {
  const client = await pool.connect();
  let discardConnection: boolean = false;
  try {
    await client.query('BEGIN');
    await client.query("SET LOCAL ROLE 'operations_hub_runtime'");
    await client.query(
      "SELECT set_config('app.user_id', $1, true)",
      [userId],
    );
    const result = await client.query(query, values);
    await client.query('COMMIT')
    return result;
  } catch (error) {
    try {
      await client.query('ROLLBACK')
    } catch (rollbackError) {
      discardConnection = true
      console.error('Transaction rollback failed:', rollbackError)
    }

    throw error
  } finally {
    client.release(discardConnection);
  }
}

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