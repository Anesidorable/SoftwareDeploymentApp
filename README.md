# SoftwareDeploymentApp

University grocery-list DevOps project.

## Local Docker setup (Windows / PowerShell)

Install and start Docker Desktop with Linux containers, then run these commands from the repository root.

For a new checkout, copy the environment template (do not overwrite an existing `.env`):

```powershell
Copy-Item .env.example .env
```

Set `DB_USER`, `DB_PASSWORD`, and `DB_NAME` in `.env` to your local PostgreSQL credentials and database name. Keep `.env` private and ignored by Git. Retain the existing values when reusing an initialized database volume.

Compose sets the API's `DB_HOST=db` and `DB_PORT=5432`. It passes the three database variables separately so the existing Prisma configuration and runtime encode the password when constructing the connection URL. `DATABASE_URL` in the template is not required or passed to the API by this Compose setup.

Build and start the checked-out API and web source:

```powershell
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d --build --wait
```

Open <http://localhost:8080>. Check the API at <http://localhost:8080/api/health> and its database-backed list at <http://localhost:8080/api/list>.

The base `docker-compose.yml` uses published GHCR API and web images. The explicit `docker-compose.local.yml` override builds `./server` and `./client` and tags them locally; source edits are exercised only when those images are rebuilt. Always include both files for local source verification. Using the base file alone runs published images, which may differ from this checkout.

Both modes use the same `softwaredeploymentapp` Compose project and named PostgreSQL volume. Stop with `docker compose -f docker-compose.yml -f docker-compose.local.yml stop`; do not use `down -v` if you want to retain the database. Changing `.env` credentials does not change credentials already stored in PostgreSQL.

## Docker repair verification

Verified on 19 October 2026:

- Both local images build successfully; PostgreSQL and API health checks pass and the web container starts.
- Both existing migrations apply; Prisma migration status is up to date.
- Homepage, JavaScript/CSS assets, `/api/health`, `/api/hello`, and `/api/list` return HTTP 200 through port 8080. The list currently returns an empty JSON array.
- The base Compose environment is also compatible with the cached published GHCR API image, image ID `sha256:d95b014d02d19efa6e00eb5d5a2bc5336bfc3e8fc98fe26b5a65e6be847a4577`: its normal migration/start command succeeds, and its health and database-list endpoints respond successfully. This checks the cached image, not a newly pulled remote `latest`. The published web image was not separately reverified.
- Existing database volume and `.env` are preserved. No dependency versions were changed.

The frontend in this branch is still the Vite starter screen; the API exposes the grocery-list read endpoint.

## Dependency audit snapshot

`npm audit --omit=dev --json` inside the locally built API reports **13 affected package entries: 8 high, 5 moderate, 0 critical, 0 low**. These are package entries, not 13 distinct advisories. All are in the installed Prisma CLI/tooling dependency tree, which is included in the production API image for migration startup.

| Severity | Affected component / packages | Summary |
| --- | --- | --- |
| High (5) | `prisma`, `@prisma/composer-cli`, `@prisma/composer`, `alchemy`, `@prisma/dev` | Inherit findings through their tooling dependencies. |
| High (2) | `hono`, `@hono/node-server` | Multiple HTTP middleware, path traversal, injection, authentication and data-isolation advisories. |
| High (1) | `lodash` | Template code injection and prototype pollution advisories. |
| Moderate (4) | `@mrleebo/prisma-ast`, `chevrotain`, `@chevrotain/cst-dts-gen`, `@chevrotain/gast` | Parser/tooling packages inherit findings through their dependencies, including lodash. |
| Moderate (1) | `valibot` | Inherited property names in record issue paths can cause `flatten()` to throw. |

The audit does not establish which vulnerable code paths this application executes. No automatic upgrades were run. Some suggested fixes change Prisma to version 7.10.1, so remediation requires a separate compatibility review of this Prisma 8 project.
