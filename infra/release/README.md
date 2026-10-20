# Release pipeline (Levels 1–4)

```
PR ──► Lint + API tests (Vitest/Supertest, real Postgres, ≥80% coverage) + image build      [Build Docker Image]
merge to main ──► same checks ──► images pushed to GHCR (tag = commit SHA)
          │
          ▼  [Release Pipeline]  (one AWS account, ap-southeast-2)
   Promote images to ECR (immutable tag, pinned by digest, release manifest)
          ▼
   Testing  (EC2, empty DB every release) ──► smoke test + Playwright E2E
          ▼
   Staging  (EC2, persistent DB) ──► smoke test + 2-minute load test (20 users, p95 ≤ 300 ms, errors < 1%)
          ▼
   Production (EC2, DB backup first) ──► monitoring setup ──► smoke test ──► auto-rollback on failure
                                         CloudWatch dashboard, 6 alarms → SNS email, container logs
```

All three servers are created from **one template** (`environment.yml`) and changed only through the pipeline.
Deployments use AWS Systems Manager, so no SSH port is open. Secrets live in Parameter Store (`/grocery/<env>/db-password`).

## Files

| File | Runs where | Purpose |
|---|---|---|
| `bootstrap.yml` | Deployed once by hand | GitHub OIDC provider, `grocery-release-github` role, ECR repos |
| `environment.yml` | Pipeline | EC2 + IAM + security group + Elastic IP; production adds alarms/dashboard/logs |
| `docker-compose.release.yml` | EC2 | db, api and web containers |
| `deploy.sh` | EC2 (via SSM) | `deploy` and `rollback` |
| `ssm-run.sh` | GitHub runner | Sends SSM commands, waits, fails on failure |
| `../../.github/actions/deploy-env` | GitHub runner | Stack update → start instance → wait for SSM → deploy |
| `../../.github/workflows/release.yml` | GitHub | The full Testing → Staging → Production chain |

## One-time setup (≈10 minutes)

1. AWS console, region **Asia Pacific (Sydney) ap-southeast-2** → CloudFormation → Create stack → upload `bootstrap.yml`.
   Stack name `grocery-release-bootstrap`. If IAM → Identity providers already lists
   `token.actions.githubusercontent.com`, set `CreateOidcProvider` to `false`.
   Tick "I acknowledge that AWS CloudFormation might create IAM resources with custom names" → Submit.
2. Copy the `ReleaseRoleArn` output into `AWS_ROLE_ARN` in `.github/workflows/release.yml`.
3. Merge to main. The first release creates the three stacks (`grocery-testing`, `grocery-staging`,
   `grocery-production`); first boot adds about 5 minutes per environment.
4. Confirm the "AWS Notification – Subscription Confirmation" email so alarms can email you.

## Running it

- **Automatic:** merge a PR to main. Watch Actions → *Build Docker Image* then *Release Pipeline*.
- **Re-run a release:** Actions → Release Pipeline → Run workflow (optionally give a commit SHA).
- **Manual rollback:** run `bash /opt/grocery-deploy.sh rollback production` on the instance via
  Systems Manager → Run Command (AWS-RunShellScript). The pipeline does this automatically when
  the production check fails.

## Cost control

Three `t3.micro` instances. To save money between sessions, stop the Testing and Staging instances
in the EC2 console. The pipeline starts them again automatically on the next release.
After marking, delete the three `grocery-*` stacks, then `grocery-release-bootstrap` (empty the ECR repositories first).

## Differences from the Project Brief (for the report)

- Tests run **from the GitHub runner against the Testing server**, not inside a test-runner container
  on that server. They still run against the deployed Testing environment before anything is promoted.
- Evidence (coverage, Playwright report, load test, release manifest) is kept as **GitHub Actions artifacts**
  instead of S3. Database backups are kept on the production instance (5 most recent), not in S3.
- Production deployment is fully automatic (no manual approval gate).
