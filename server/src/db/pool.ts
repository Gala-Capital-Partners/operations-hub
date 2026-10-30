import { Pool } from 'pg'

/**
 * Creates the backend's database connection pool.
 * Call once during application startup, after loading .env.
 */
export function createDatabasePool(): Pool {
  const connectionString = process.env.DATABASE_URL

  if (!connectionString) {
    throw new Error('Missing DATABASE_URL configuration')
  }

  const pool = new Pool({
    connectionString,
    max: 5,
    connectionTimeoutMillis: 5000,
    idleTimeoutMillis: 30000,
  })

  // Handle connection failures that occur while connections are idle.
  pool.on('error', () => {
    console.error('An idle database connection failed')
  })

  return pool
}