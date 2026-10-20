import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    environment: 'node',
    include: ['test/**/*.test.js'],
    // Integration tests share one database, so run files one at a time.
    fileParallelism: false,
    coverage: {
      provider: 'v8',
      include: ['app.js'],
      reporter: ['text', 'json-summary', 'html'],
      reportsDirectory: 'coverage',
      // Project Brief target: at least 80% of API code covered.
      thresholds: { lines: 80, statements: 80 },
    },
  },
})
