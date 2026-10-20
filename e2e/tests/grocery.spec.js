// End-to-end acceptance tests: the core user journeys from Project Brief 1.3.
import { expect, test } from '@playwright/test'

const unique = (label) => `${label} ${Date.now()}-${Math.floor(Math.random() * 1000)}`

async function addItem(page, name, quantity = '2', category = 'Produce') {
  await page.getByLabel('ITEM NAME').fill(name)
  await page.getByLabel('QUANTITY').fill(quantity)
  await page.getByLabel('CATEGORY').selectOption(category)
  await page.getByRole('button', { name: '＋ Add item' }).click()
  await expect(page.getByRole('status')).toHaveText('Item saved successfully.')
}

const row = (page, name) => page.locator('.grocery-item', { hasText: name })

test.beforeEach(async ({ page }) => {
  await page.goto('/')
  await expect(page.getByRole('heading', { level: 1 })).toContainText('My grocery list')
  await expect(page.getByText('Loading grocery items...')).toBeHidden()
})

test('shows the running version in the footer', async ({ page }) => {
  const footer = page.getByTestId('version-footer')
  await expect(footer).toContainText('Version')
  await expect(footer).not.toContainText('unavailable')
})

test('adds an item and keeps it after a reload', async ({ page }) => {
  const name = unique('Apples')
  await addItem(page, name, '3')

  await expect(row(page, name)).toContainText('Qty: 3')
  await page.reload()
  await expect(row(page, name)).toBeVisible()
})

test('marks an item as purchased', async ({ page }) => {
  const name = unique('Milk')
  await addItem(page, name, '1', 'Dairy')

  await row(page, name).getByRole('checkbox').click()
  await expect(row(page, name)).toHaveClass(/is-purchased/)
  await expect(row(page, name).getByText('Purchased')).toBeVisible()

  await page.reload()
  await expect(row(page, name).getByRole('checkbox')).toBeChecked()
})

test('deletes an item', async ({ page }) => {
  const name = unique('Bread')
  await addItem(page, name, '1', 'Bakery')

  await page.getByRole('button', { name: `Remove ${name}` }).click()
  await expect(page.getByRole('status')).toHaveText('Item removed successfully.')
  await expect(row(page, name)).toHaveCount(0)

  await page.reload()
  await expect(row(page, name)).toHaveCount(0)
})

test('filters by purchase status and searches by name', async ({ page }) => {
  const bought = unique('Cheese')
  const notBought = unique('Rice')
  await addItem(page, bought, '1', 'Dairy')
  await addItem(page, notBought, '1', 'Pantry')
  await row(page, bought).getByRole('checkbox').click()
  await expect(row(page, bought)).toHaveClass(/is-purchased/)

  await page.locator('.filter-buttons').getByRole('button', { name: 'Purchased' }).click()
  await expect(row(page, bought)).toBeVisible()
  await expect(row(page, notBought)).toHaveCount(0)

  await page.locator('.filter-buttons').getByRole('button', { name: 'All' }).click()
  await page.getByLabel('Search grocery items').fill(notBought)
  await expect(row(page, notBought)).toBeVisible()
  await expect(row(page, bought)).toHaveCount(0)
})

test('does not add an item with an invalid quantity', async ({ page }) => {
  const name = unique('Eggs')
  await page.getByLabel('ITEM NAME').fill(name)
  await page.getByLabel('QUANTITY').fill('0')
  await page.getByRole('button', { name: '＋ Add item' }).click()

  await expect(page.locator('#item-quantity:invalid')).toHaveCount(1)
  await expect(row(page, name)).toHaveCount(0)
})
