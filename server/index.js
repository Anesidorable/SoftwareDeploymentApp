import app, { pool } from './app.js'

const PORT = process.env.PORT || 5000
const HOST = process.env.HOST || '127.0.0.1'

const server = app.listen(PORT, HOST, () => {
  console.log(`API on ${HOST}:${PORT}`)
})

process.on('SIGTERM', () => {
  server.close(async () => {
    await pool.end()
    process.exit(0)
  })

  setTimeout(() => process.exit(1), 10000).unref()
})
