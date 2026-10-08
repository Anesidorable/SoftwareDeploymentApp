const express = require('express');

const app = express();
const PORT = process.env.PORT || 5000;
const HOST = process.env.HOST || '127.0.0.1';
app.set('trust proxy', Number(process.env.TRUST_PROXY ?? 1));
app.use(express.json());

app.get('/api/health', (req, res) =>
  res.json({
    status: 'ok',
    env: process.env.APP_ENV || 'local',
    version: process.env.GIT_SHA || 'dev',
  })
);

app.get('/api/hello', (req, res) => res.json({ message: 'Hello from Express!' }));

const server = app.listen(PORT, HOST, () => console.log(`API on ${HOST}:${PORT}`));

process.on('SIGTERM', () => {
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 10000).unref();
});