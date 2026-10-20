// Integration tests: real HTTP requests to the Express app, backed by a real PostgreSQL database.
// Requires DATABASE_URL pointing at a migrated database (see .github/workflows/test.yml).
import { afterAll, beforeEach, describe, expect, it } from 'vitest'
import request from 'supertest'
import app, { pool } from '../app.js'

beforeEach(async () => {
  await pool.query('TRUNCATE "GroceryList" RESTART IDENTITY')
})

afterAll(async () => {
  await pool.end()
})

async function addItem(body = { name: 'Bananas', quantity: 6, category: 'Produce' }) {
  return request(app).post('/api/list').send(body)
}

describe('health and version', () => {
  it('GET /api/health reports ok with a connected database', async () => {
    const res = await request(app).get('/api/health')
    expect(res.status).toBe(200)
    expect(res.body).toMatchObject({ status: 'ok', database: 'connected' })
  })

  it('GET /api/version returns the running release', async () => {
    const res = await request(app).get('/api/version')
    expect(res.status).toBe(200)
    expect(res.body).toHaveProperty('version')
    expect(res.body).toHaveProperty('env')
  })

  it('GET /api/hello responds', async () => {
    const res = await request(app).get('/api/hello')
    expect(res.status).toBe(200)
  })
})

describe('create and read items', () => {
  it('starts with an empty list', async () => {
    const res = await request(app).get('/api/list')
    expect(res.status).toBe(200)
    expect(res.body).toEqual([])
  })

  it('adds an item and returns it', async () => {
    const res = await addItem()
    expect(res.status).toBe(201)
    expect(res.body).toMatchObject({ name: 'Bananas', quantity: 6, category: 'Produce', purchased: false })

    const list = await request(app).get('/api/list')
    expect(list.body).toHaveLength(1)
    expect(list.body[0].name).toBe('Bananas')
  })

  it('trims names and uses defaults for quantity and category', async () => {
    const res = await addItem({ name: '  Bread  ' })
    expect(res.status).toBe(201)
    expect(res.body).toMatchObject({ name: 'Bread', quantity: 1, category: 'Other' })
  })

  it.each([
    ['an empty name', { name: '   ' }],
    ['a missing name', { quantity: 2 }],
    ['a name over 100 characters', { name: 'x'.repeat(101) }],
    ['a quantity of 0', { name: 'Eggs', quantity: 0 }],
    ['a quantity over 999', { name: 'Eggs', quantity: 1000 }],
    ['a decimal quantity', { name: 'Eggs', quantity: 1.5 }],
    ['an unknown category', { name: 'Eggs', category: 'Toys' }],
  ])('rejects %s with 400', async (_label, body) => {
    const res = await addItem(body)
    expect(res.status).toBe(400)
    expect(res.body.error).toBeTruthy()
  })
})

describe('update items', () => {
  it('marks an item as purchased and back again', async () => {
    const { body: item } = await addItem()

    const bought = await request(app).patch(`/api/list/${item.id}`).send({ purchased: true })
    expect(bought.status).toBe(200)
    expect(bought.body.purchased).toBe(true)

    const unbought = await request(app).patch(`/api/list/${item.id}`).send({ purchased: false })
    expect(unbought.body.purchased).toBe(false)
  })

  it('rejects a non-boolean purchased value', async () => {
    const { body: item } = await addItem()
    const res = await request(app).patch(`/api/list/${item.id}`).send({ purchased: 'yes' })
    expect(res.status).toBe(400)
  })

  it('returns 400 for an invalid id and 404 for a missing item', async () => {
    expect((await request(app).patch('/api/list/abc').send({ purchased: true })).status).toBe(400)
    expect((await request(app).patch('/api/list/999').send({ purchased: true })).status).toBe(404)
  })
})

describe('delete items', () => {
  it('deletes an item', async () => {
    const { body: item } = await addItem()
    const res = await request(app).delete(`/api/list/${item.id}`)
    expect(res.status).toBe(204)

    const list = await request(app).get('/api/list')
    expect(list.body).toEqual([])
  })

  it('returns 400 for an invalid id and 404 for a missing item', async () => {
    expect((await request(app).delete('/api/list/0')).status).toBe(400)
    expect((await request(app).delete('/api/list/999')).status).toBe(404)
  })
})

describe('database failures', () => {
  it('returns 500 errors instead of crashing when the database rejects a query', async () => {
    await pool.query('ALTER TABLE "GroceryList" RENAME TO "GroceryListOffline"')
    try {
      expect((await addItem()).status).toBe(500)
      expect((await request(app).get('/api/list')).status).toBe(500)
      expect((await request(app).patch('/api/list/1').send({ purchased: true })).status).toBe(500)
      expect((await request(app).delete('/api/list/1')).status).toBe(500)
    } finally {
      await pool.query('ALTER TABLE "GroceryListOffline" RENAME TO "GroceryList"')
    }
  })
})
