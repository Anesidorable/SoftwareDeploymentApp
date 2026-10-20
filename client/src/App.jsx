
import { useEffect, useMemo, useState } from 'react'
import './App.css'

const categories = [
  'Produce',
  'Dairy',
  'Meat & Seafood',
  'Bakery',
  'Pantry',
  'Frozen',
  'Other',
]

const categoryIcons = {
  Produce: '🥬',
  Dairy: '🥛',
  'Meat & Seafood': '🥩',
  Bakery: '🥖',
  Pantry: '🥫',
  Frozen: '🧊',
  Other: '🛒',
}


function normaliseItem(item, index) {
  return {
    id: item.id ?? `api-${index}`,
    name: item.name ?? item.item ?? 'Unnamed item',
    quantity: item.quantity ?? item.count ?? 1,
    category: categories.includes(item.category ?? item.notes)
      ? (item.category ?? item.notes)
      : 'Other',
    purchased: Boolean(
      item.purchased ?? item.ticked ?? false
    ),
  }
}


async function apiRequest(url, options = {}) {
  const response = await fetch(url, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...options.headers,
    },
  })

  if (!response.ok) {
    const data = await response.json().catch(() => ({}))
    throw new Error(data.error || `Request failed (${response.status})`)
  }

  if (response.status === 204) {
    return null
  }

  return response.json()
}


function App() {
  const [items, setItems] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [search, setSearch] = useState('')
  const [filter, setFilter] = useState('All')
  const [newItem, setNewItem] = useState('')
  const [newQuantity, setNewQuantity] = useState(1)
  const [newCategory, setNewCategory] = useState('Produce')
  const [notice, setNotice] = useState('')
  const [release, setRelease] = useState(null)

  // Show which release is running, so each deployment is visible on the page.
  useEffect(() => {
    fetch('/api/version')
      .then((response) => (response.ok ? response.json() : null))
      .then(setRelease)
      .catch(() => setRelease(null))
  }, [])

  useEffect(() => {
    async function loadItems() {
      try {
        const response = await fetch('/api/list')

        if (!response.ok) {
          throw new Error(`API returned ${response.status}`)
        }

        const data = await response.json()

        if (!Array.isArray(data)) {
          throw new Error('Unexpected grocery list response')
        }

        setItems(data.map(normaliseItem))
        setError('')
      } catch {
        setError(
          'Could not load grocery items from the API. You can still try the interface locally.'
        )
      } finally {
        setLoading(false)
      }
    }

    loadItems()
  }, [])

  const totalItems = items.length
  const purchasedCount = items.filter((item) => item.purchased).length
  const remainingCount = totalItems - purchasedCount
  const progress = totalItems
    ? Math.round((purchasedCount / totalItems) * 100)
    : 0

  const filteredItems = useMemo(() => {
    return items.filter((item) => {
      const matchesSearch = item.name
        .toLowerCase()
        .includes(search.toLowerCase())

      const matchesFilter =
        filter === 'All' ||
        (filter === 'Remaining' && !item.purchased) ||
        (filter === 'Purchased' && item.purchased) ||
        item.category === filter

      return matchesSearch && matchesFilter
    })
  }, [items, search, filter])

  const groupedItems = useMemo(() => {
    return categories
      .map((category) => ({
        category,
        items: filteredItems.filter((item) => item.category === category),
      }))
      .filter((group) => group.items.length > 0)
  }, [filteredItems])

  
  async function addItem(event) {
    event.preventDefault()

    const name = newItem.trim()
    const quantity = Number(newQuantity)

    if (!name || !Number.isInteger(quantity) || quantity < 1 || quantity > 999) {
      setError('Enter an item name and a valid quantity between 1 and 999.')
      return
    }

    try {
      const savedItem = await apiRequest('/api/list', {
        method: 'POST',
        body: JSON.stringify({
          name,
          quantity,
          category: newCategory,
        }),
      })

      setItems((current) => [normaliseItem(savedItem), ...current])
      setNewItem('')
      setNewQuantity(1)
      setFilter('All')
      setError('')
      setNotice('Item saved successfully.')
    } catch (err) {
      setError(err.message)
    }
  }

  async function togglePurchased(id) {
    const item = items.find((entry) => entry.id === id)
    if (!item) return

    try {
      const updatedItem = await apiRequest(`/api/list/${id}`, {
        method: 'PATCH',
        body: JSON.stringify({
          purchased: !item.purchased,
        }),
      })

      setItems((current) =>
        current.map((entry) =>
          entry.id === id ? normaliseItem(updatedItem) : entry
        )
      )

      setError('')
      setNotice('Item updated successfully.')
    } catch (err) {
      setError(err.message)
    }
  }

  async function deleteItem(id) {
    try {
      await apiRequest(`/api/list/${id}`, {
        method: 'DELETE',
      })

      setItems((current) =>
        current.filter((item) => item.id !== id)
      )

      setError('')
      setNotice('Item removed successfully.')
    } catch (err) {
      setError(err.message)
    }
  }

  async function clearPurchased() {
    const purchasedItems = items.filter((item) => item.purchased)

    try {
      const results = await Promise.allSettled(
        purchasedItems.map((item) =>
          apiRequest(`/api/list/${item.id}`, {
            method: 'DELETE',
          })
        )
      )

      const deletedIds = purchasedItems
        .filter((_, index) => results[index].status === 'fulfilled')
        .map((item) => item.id)

      setItems((current) =>
        current.filter((item) => !deletedIds.includes(item.id))
      )

      const failures = results.filter(
        (result) => result.status === 'rejected'
      )

      if (failures.length > 0) {
        setError(`${failures.length} item(s) could not be removed.`)
        setNotice('')
      } else {
        setError('')
        setNotice('Purchased items cleared successfully.')
      }
    } catch (err) {
      setError(err.message)
    }
  }


  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand">
          <div className="brand-icon">✳</div>
          <div>
            <div className="brand-name">GroceryList<span>.</span></div>
            <div className="brand-caption">Your shopping companion</div>
          </div>
        </div>

        <div className="sidebar-section-label">WORKSPACE</div>

        <nav className="navigation" aria-label="Main navigation">
          <button
            className="nav-link active"
            onClick={() => setFilter('All')}
          >
            <span>▦</span> My grocery list
          </button>
          <button
            className="nav-link"
            onClick={() => setFilter('Purchased')}
          >
            <span>✓</span> Purchased items
          </button>
        </nav>

        <div className="sidebar-section-label categories-heading">
          CATEGORIES
        </div>

        <nav className="navigation" aria-label="Categories">
          {categories.map((category) => (
            <button
              key={category}
              className={`nav-link ${filter === category ? 'selected' : ''}`}
              onClick={() => setFilter(category)}
            >
              <span>{categoryIcons[category]}</span>
              {category}
            </button>
          ))}
        </nav>

        <div className="sidebar-footer">
          <div className="sidebar-footer-icon">✦</div>
          <strong>Shop smarter.</strong>
          <p>Everything you need, all in one list.</p>
        </div>
      </aside>

      <main className="main-content">
        <header className="topbar">
          <div className="breadcrumb">
            Workspace <span>/</span> <strong>My grocery list</strong>
          </div>
          <div className="topbar-right">
            <span className="environment-tag">GROCERY DASHBOARD</span>
            <div className="avatar">FL</div>
          </div>
        </header>

        <div className="page-content">
          <div className="page-heading">
            <div>
              <div className="eyebrow">YOUR SHOPPING SPACE</div>
              <h1>My grocery list <span>🛒</span></h1>
              <p>
                Stay organised, shop efficiently, and never forget
                an item again.
              </p>
            </div>
            <button
              className="primary-button heading-button"
              onClick={() => document.getElementById('item-name')?.focus()}
            >
              <span>＋</span> Add new item
            </button>
          </div>

          <section className="stats-grid" aria-label="Shopping statistics">
            <div className="stat-card">
              <div className="stat-top">
                <span>Total items</span>
                <div className="stat-icon purple">▤</div>
              </div>
              <div className="stat-number">{totalItems}</div>
              <div className="stat-description">On your shopping list</div>
            </div>

            <div className="stat-card">
              <div className="stat-top">
                <span>Still to get</span>
                <div className="stat-icon orange">◷</div>
              </div>
              <div className="stat-number">{remainingCount}</div>
              <div className="stat-description">Items remaining</div>
            </div>

            <div className="stat-card">
              <div className="stat-top">
                <span>Purchased</span>
                <div className="stat-icon green">✓</div>
              </div>
              <div className="stat-number">{purchasedCount}</div>
              <div className="stat-description">Already in your basket</div>
            </div>
          </section>

          <section className="progress-card">
            <div className="progress-info">
              <div>
                <h2>Shopping progress</h2>
                <p>You're making great progress on your list.</p>
              </div>
              <div className="progress-percent">{progress}%</div>
            </div>
            <div
              className="progress-track"
              role="progressbar"
              aria-valuenow={progress}
              aria-valuemin="0"
              aria-valuemax="100"
              aria-label="Shopping progress"
            >
              <div
                className="progress-fill"
                style={{ width: `${progress}%` }}
              />
            </div>
            <div className="progress-bottom">
              <span>{purchasedCount} of {totalItems} items purchased</span>
              <span>{remainingCount} remaining</span>
            </div>
          </section>

          <section className="add-card">
            <div className="section-heading">
              <div>
                <h2>Add to your list</h2>
                <p>What do you need to pick up?</p>
              </div>
            </div>

            <form className="add-form" onSubmit={addItem}>
              <div className="field item-field">
                <label htmlFor="item-name">ITEM NAME</label>
                <input
                  id="item-name"
                  type="text"
                  placeholder="e.g. Strawberries"
                  value={newItem}
                  maxLength={100}
                  onChange={(event) => setNewItem(event.target.value)}
                />
              </div>

              <div className="field quantity-field">
                <label htmlFor="item-quantity">QUANTITY</label>
                <input
                  id="item-quantity"
                  type="number"
                  min="1"
                  max="999"
                  value={newQuantity}
                  onChange={(event) => setNewQuantity(event.target.value)}
                />
              </div>

              <div className="field category-field">
                <label htmlFor="item-category">CATEGORY</label>
                <select
                  id="item-category"
                  value={newCategory}
                  onChange={(event) => setNewCategory(event.target.value)}
                >
                  {categories.map((category) => (
                    <option key={category} value={category}>
                      {category}
                    </option>
                  ))}
                </select>
              </div>

              <button className="primary-button add-submit" type="submit">
                ＋ Add item
              </button>
            </form>

            {notice && (
              <p className="local-notice" role="status">{notice}</p>
            )}
          </section>

          <section className="list-card">
            <div className="list-heading">
              <div>
                <h2>Shopping list <span className="count-pill">{totalItems}</span></h2>
                <p>Everything you need for your next shop.</p>
              </div>
              <button
                className="clear-button"
                onClick={clearPurchased}
                disabled={purchasedCount === 0}
              >
                Clear purchased
              </button>
            </div>

            <div className="list-toolbar">
              <div className="search-wrapper">
                <span>⌕</span>
                <input
                  type="search"
                  placeholder="Search your items..."
                  value={search}
                  onChange={(event) => setSearch(event.target.value)}
                  aria-label="Search grocery items"
                />
              </div>

              <div className="filter-buttons">
                {['All', 'Remaining', 'Purchased'].map((option) => (
                  <button
                    key={option}
                    className={filter === option ? 'filter active' : 'filter'}
                    onClick={() => setFilter(option)}
                  >
                    {option}
                  </button>
                ))}
              </div>
            </div>

            {error && <div className="error-message" role="alert">{error}</div>}

            {loading ? (
              <div className="empty-state">Loading grocery items...</div>
            ) : groupedItems.length === 0 ? (
              <div className="empty-state">
                <div className="empty-icon">🛒</div>
                <h3>No items to show</h3>
                <p>
                  {search || filter !== 'All'
                    ? 'Try changing your search or filters.'
                    : 'Your grocery list is empty. Add your first item above!'}
                </p>
              </div>
            ) : (
              <div className="item-groups">
                {groupedItems.map((group) => (
                  <div className="item-group" key={group.category}>
                    <div className="group-heading">
                      <span>{categoryIcons[group.category]}</span>
                      <strong>{group.category}</strong>
                      <span className="group-count">{group.items.length}</span>
                    </div>

                    {group.items.map((item) => (
                      <div
                        className={`grocery-item ${item.purchased ? 'is-purchased' : ''}`}
                        key={item.id}
                      >
                        <label className="item-main">
                          <input
                            type="checkbox"
                            checked={item.purchased}
                            onChange={() => togglePurchased(item.id)}
                          />
                          <span className="item-name">{item.name}</span>
                        </label>

                        <div className="item-actions">
                          <span className="quantity-badge">
                            Qty: {item.quantity}
                          </span>
                          {item.purchased && (
                            <span className="purchased-badge">Purchased</span>
                          )}
                          <button
                            className="delete-button"
                            onClick={() => deleteItem(item.id)}
                            aria-label={`Remove ${item.name}`}
                            title="Remove item"
                          >
                            ×
                          </button>
                        </div>
                      </div>
                    ))}
                  </div>
                ))}
              </div>
            )}
          </section>

          <footer className="version-footer" data-testid="version-footer">
            {release
              ? `Version ${String(release.version).slice(0, 7)} · ${release.env}`
              : 'Version unavailable'}
          </footer>
        </div>
      </main>
    </div>
  )
}

export default App
