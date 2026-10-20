// Unit tests: pure helper functions, no database needed.
import { describe, expect, it } from 'vitest'
import { formatItem, validId } from '../app.js'

describe('validId', () => {
  it('accepts positive whole numbers', () => {
    expect(validId('1')).toBe(1)
    expect(validId('42')).toBe(42)
  })

  it.each(['0', '-3', '1.5', 'abc', '', '9007199254740993'])('rejects %j', (value) => {
    expect(validId(value)).toBeNull()
  })
})

describe('formatItem', () => {
  it('maps database columns to the API shape', () => {
    const row = { id: 7, item: 'Milk', count: 2, notes: 'Dairy', ticked: true }
    expect(formatItem(row)).toEqual({
      id: 7,
      name: 'Milk',
      quantity: 2,
      category: 'Dairy',
      purchased: true,
    })
  })

  it('falls back to "Other" for unknown or missing categories', () => {
    expect(formatItem({ id: 1, item: 'X', count: 1, notes: 'Toys', ticked: false }).category).toBe('Other')
    expect(formatItem({ id: 1, item: 'X', count: 1, notes: null, ticked: false }).category).toBe('Other')
  })
})
