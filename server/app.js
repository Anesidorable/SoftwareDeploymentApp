import { db } from './db.js'
import express from 'express'
import pg from 'pg'

const { Pool } = pg

const app = express()

app.set('trust proxy', Number(process.env.TRUST_PROXY ?? 1))
app.use(express.json())

const connectionString =
  process.env.DATABASE_URL ||
  `postgresql://${process.env.DB_USER}:${encodeURIComponent(
    process.env.DB_PASSWORD || ''
  )}@${process.env.DB_HOST || 'localhost'}:${process.env.DB_PORT || '5432'}/${process.env.DB_NAME}`

export const pool = new Pool({ connectionString })

const categories = [
  'Produce',
  'Dairy',
  'Meat & Seafood',
  'Bakery',
  'Pantry',
  'Frozen',
  'Other',
]

export function formatItem(row) {
  return {
    id: row.id,
    name: row.item,
    quantity: row.count,
    category: categories.includes(row.notes) ? row.notes : 'Other',
    purchased: row.ticked,
  }
}

export function validId(value) {
  const id = Number(value)
  return Number.isSafeInteger(id) && id > 0 ? id : null
}

// Health check used by the pipeline: only "ok" when the database answers.
app.get('/api/health', async (req, res) => {
  const body = {
    env: process.env.APP_ENV || 'local',
    version: process.env.GIT_SHA || 'dev',
  }

  try {
    await pool.query('SELECT 1')
    res.json({ status: 'ok', database: 'connected', ...body })
  } catch (error) {
    console.error('Health check failed:', error.message)
    res.status(503).json({ status: 'error', database: 'unreachable', ...body })
  }
})

// Which release is running (commit SHA and build time), shown in the page footer.
app.get('/api/version', (req, res) => {
  res.json({
    version: process.env.GIT_SHA || 'dev',
    builtAt: process.env.BUILD_TIME || null,
    env: process.env.APP_ENV || 'local',
  })
})

app.get('/api/hello', (req, res) => {
  res.json({ message: 'Hello from Express!' })
})

// Retrieve all grocery items.
app.get('/api/list', async (req, res) => {
  try {
    const items = await db.orm.public.GroceryList.all()
    res.json(items.map(formatItem))
  } catch (error) {
    console.error('Failed to retrieve grocery list:', error)
    res.status(500).json({ error: 'Failed to fetch grocery list items.' })
  }
})

// Add a new grocery item.
app.post('/api/list', async (req, res) => {
  const { name, quantity = 1, category = 'Other' } = req.body || {}

  if (typeof name !== 'string' || !name.trim() || name.trim().length > 100) {
    return res.status(400).json({
      error: 'Item name must contain between 1 and 100 characters.',
    })
  }

  if (
    typeof quantity !== 'number' ||
    !Number.isInteger(quantity) ||
    quantity < 1 ||
    quantity > 999
  ) {
    return res.status(400).json({
      error: 'Quantity must be a whole number between 1 and 999.',
    })
  }

  if (!categories.includes(category)) {
    return res.status(400).json({ error: 'Invalid category.' })
  }

  try {
    const result = await pool.query(
      `INSERT INTO "GroceryList" ("item", "count", "notes", "ticked")
       VALUES ($1, $2, $3, false)
       RETURNING *`,
      [name.trim(), quantity, category]
    )

    res.status(201).json(formatItem(result.rows[0]))
  } catch (error) {
    console.error('Failed to add grocery item:', error)
    res.status(500).json({ error: 'Failed to add grocery item.' })
  }
})

// Update an item's purchased status.
app.patch('/api/list/:id', async (req, res) => {
  const id = validId(req.params.id)

  if (id === null) {
    return res.status(400).json({ error: 'Invalid item ID.' })
  }

  const { purchased } = req.body || {}

  if (typeof purchased !== 'boolean') {
    return res.status(400).json({
      error: 'Purchased must be true or false.',
    })
  }

  try {
    const result = await pool.query(
      `UPDATE "GroceryList"
       SET "ticked" = $1
       WHERE "id" = $2
       RETURNING *`,
      [purchased, id]
    )

    if (result.rowCount === 0) {
      return res.status(404).json({ error: 'Item not found.' })
    }

    res.json(formatItem(result.rows[0]))
  } catch (error) {
    console.error('Failed to update grocery item:', error)
    res.status(500).json({ error: 'Failed to update grocery item.' })
  }
})

// Delete a grocery item.
app.delete('/api/list/:id', async (req, res) => {
  const id = validId(req.params.id)

  if (id === null) {
    return res.status(400).json({ error: 'Invalid item ID.' })
  }

  try {
    const result = await pool.query(
      `DELETE FROM "GroceryList"
       WHERE "id" = $1
       RETURNING "id"`,
      [id]
    )

    if (result.rowCount === 0) {
      return res.status(404).json({ error: 'Item not found.' })
    }

    res.status(204).send()
  } catch (error) {
    console.error('Failed to delete grocery item:', error)
    res.status(500).json({ error: 'Failed to delete grocery item.' })
  }
})

export default app
