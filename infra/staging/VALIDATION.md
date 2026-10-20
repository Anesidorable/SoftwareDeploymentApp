# Staging deployment and live verification — 2026-10-20

## Current result

PASS. Website: http://54.159.81.113
Release: 2aa5022552b88094760cee0bc76a7ecfb2163448
CI: https://github.com/Anesidorable/SoftwareDeploymentApp/actions/runs/39379318432
Registry: 960607644670.dkr.ecr.us-east-1.amazonaws.com

Account/profile/region: 245606545178 / learnerlab / us-east-1
Stack: grocery-staging (CREATE_COMPLETE)
Stack ID: arn:aws:cloudformation:us-east-1:245606545178:stack/grocery-staging/8964d510-cc76-11f1-824a-0affc7ccc753
Instance: i-00e4de616bb12dc49
Data volume: vol-0669434c058070f39
Preserved ext4 UUID: 8402756a-0f61-4f56-88ba-cb6efb1e3ded


Selected immutable image indexes:

| Image | Index digest |
| --- | --- |
| API | sha256:02d7d6e7a8f3fd5ba5f4742af3bc84a30377dad61c04e012510ae3857a843c2e |
| Web | sha256:7be399dd5f76166f3432c0ef26bb827b5513cfdf2be1ab4ecb721334aee90e59 |

## Prerequisites and safe retry

The previous deployment stopped because secret hydration rejected the then-short
password. The owner updated the existing SecureString; metadata showed version 2,
alias/aws/ssm. No secret value was displayed or retrieved locally.

Reran script parsing, immutable-index and SSM failure handling tests plus
ValidateOnly. Account, subnet/routing, existing profile, region-aware permission
simulations, secret metadata, exact ECR indexes and amd64 child checks passed.
Earlier published-image integration tests passed actual migrations, special
password characters, proxy/API/database and container-recreation persistence.

Before retry, remote inspection asserted the exact volume serial, existing ext4
filesystem/UUID and mount. Database was not initialized. One initial read-only
inspection failed because Docker was inactive; a separate inspection recorded
service state without requiring a running daemon. No initialization was attempted
during inspection.

ResumeExisting pinned the existing instance, volume and filesystem UUID, skipped
CloudFormation change sets and prohibited formatting. The corrected wipefs
--output fix remains in deploy.sh for new blank disks; this resumed deployment
used only the existing-filesystem path. It explicitly started Docker after
successful secret hydration.

The controller uploaded deploy.sh, secrets.py, verify.py and nonsecret config.json
to EC2 and SHA-256 checked every transferred file BEFORE execution. Local edits
were not assumed to be remote. Observed deployed script hashes:

- deploy.sh: e9855ef1a6cd28ae1f1575880a37bd61061c360d646012e704d96775d7a807c4
- secrets.py: 64e8cbab7f08148c0c6b4d3feec71bb25c13e1f9acd4d9df60d3b97a433dfeb1
- verify.py: 331df4481d29380bc32789005b889ccacc2912e4e120da738f0d06dd546017fa

## Actual command evidence

Every command below completed with SSM Status=Success and ResponseCode=0:

| Phase | Command ID |
| --- | --- |
| Disk/service inspection | c00c2795-fde2-4bde-a2ab-de3cdaa1c670 |
| Resumed deployment | 7c153e58-7cfd-4607-98de-2ccce25901d4 |
| Seed temporary record | 8f46f0a1-fe26-4ac7-ad15-b1edafc5239e |
| Recreate DB container | 63e1b44d-8f5c-47bb-8c05-22c5448818cf |
| Verify after controlled reboot | 9395dcda-fb32-4e6b-844e-14d00a7f5e73 |
| Remove record and final verification | d498f6c8-f417-49e9-be55-fad63da19c8c |

Instance-side secret retrieval, ECR authentication and immutable API/web pulls
succeeded. The pinned PostgreSQL image was pulled, DB initialized, readiness
passed, pre-migration backup was written, and npx --no-install prisma db migrate
exited successfully. API then started separately with node index.js.

Database, API and web Docker health checks passed. Running image refs and IDs
matched the selected release; API/web RepoDigests matched the locked indexes.
Only web port 80 was published; DB/API remained internal. Direct SQL SELECT 1,
database-backed /api/list, exact /api/health release/env, frontend HTML/assets,
and Nginx proxy all passed.

The public website returned HTTP 200; public /api/health reported staging and the
selected commit, and /api/list succeeded. No application records were printed.

## Live persistence and cleanup

A unique temporary record (id 1) was inserted and verified through the API.
Only staging-db was removed/recreated; API/web were stopped/restarted around
that operation. The same mounted PostgreSQL directory was retained.

Old DB container: eef29497c16a27ba1dc5e31aa8e526cd7747cc41c4b18964cf837c8d3044dcc1
New DB container: 63fcd990fbac16675ff53cc6320eb2eb65a653331048d61a5e6f2e3cb4f12872

The record survived and all containers returned healthy.

An explicitly authorized ec2 reboot-instances request targeted only
i-00e4de616bb12dc49. The kernel boot ID changed:

- Before: 0946086e-6a0b-4777-81fe-4d71bac19fc6
- After: 24251d3f-aa5e-4639-b3ab-3a2f3470bdd9

After reboot the original ext4 UUID was mounted, secret hydration was active,
Docker restored the same digest-pinned application automatically, all containers
became healthy, and the record remained visible through the API.

Cleanup removed only that unique id/item pair, confirmed it absent through the
API, and removed transient validation state. Final database row count was 0.
A nonsecret persistence result remains on EC2 at
/srv/grocery-staging/releases/persistence-verification.json.

verification-evidence.json contains sanitized status codes, script hashes, runtime
digests, boot IDs and final external checks. The standalone verify.py does not
itself reboot or exercise persistence; those results come from the explicit
persistence-check.py phases above.

## Preservation and remaining limits

The original Staging instance, volume and filesystem were retained. No disk was
wiped or reformatted. Testing, Production, protected test instance and lab-managed
IAM were not modified. No push or merge was performed.

All requested deployment, container persistence, controlled reboot and cleanup
checks passed. Not exercised: EC2 stop/start (distinct from reboot), volume loss,
retained-volume reattachment, off-volume backup restore, disaster recovery and
schema rollback. Retained EBS and same-volume logical backups are not protection
against volume loss. HTTP is the configured Staging endpoint; no TLS was added.

## Submission review — 2026-10-20

The completed branch/worktree proposal was compared with its merge base and
current public main 2aa5022552b88094760cee0bc76a7ecfb2163448. All proposed paths are
under infra/staging. The local origin/main ref was older than public main; current
main workflow definitions were inspected directly without updating Git refs,
merging, or changing teammate files.

All proposed files, including this document and verification-evidence.json, were
reviewed for credential patterns and sensitive output. No exposed credential/token
candidates were found. The only literal password-like fixture is explicitly
labelled validation-only in Test-Staging.ps1 and was not used for deployed Staging.
Evidence includes operational IDs, digests, hashes, statuses, boot IDs and row
counts; it contains no raw secret values, authorization tokens, API record payloads
or unsanitized application/SSM logs. No secret values were retrieved for this review.

Live results above and verification-evidence.json are reused from the completed
deployment. No AWS resources, deployment, container recreation, reboot or other
disruptive live tests were repeated during submission review.

### Sydney restriction and Virginia resolution

Earlier exact-resource simulations returned explicitDeny and
AllowedByOrganizations=false for both roles with requested region ap-southeast-2;
us-east-1 context returned allowed and AllowedByOrganizations=true. The exact SCP
could not be inspected because organization/policy reads were denied. This
attribution is limited to the returned Organizations decision, not guessed policy
text. The registry owner provided the explicitly selected newer release in
Virginia, where exact digest reads and actual LabRole pulls subsequently passed.
No SCP or lab-managed IAM role was changed; Sydney was not unblocked.

### Feature status for team review

- Implemented and live-verified: manual immutable-digest deployment, secure secret
  hydration, migrations, health checks, encrypted persistent storage, no-format
  resume, container-recreation/reboot persistence and temporary-record cleanup.
- Not configured by Staging: performance agent/custom metrics/alarms/dashboard,
  centralized logs/alerts, performance benchmark, GitHub Actions Staging deployment
  or automatic Virginia image promotion. Docker health checks are availability
  probes, not a performance-monitoring system. Basic AWS EC2 monitoring defaults
  were not separately verified as a monitoring solution.
- Current main's CI builds/publishes GHCR and Sydney ECR. A Staging-only PR triggers
  Lint on pull_request; the same merge paths do not trigger the filtered main-push
  Lint/Build workflows, so this merge does not cause a qualifying Production
  deployment. Later matching app/workflow pushes or manual workflow dispatch can
  trigger the team's existing Production flow. Repository branch-protection and
  required-check settings were not inspected.

### Demo check — 21 October 2026, Australia/Sydney

Use the read-only procedure in README.md before presenting: confirm learnerlab
account, stack outputs, expected instance/volume, running state and EC2/SSM health;
derive the current public IP; request frontend, /api/health and /api/list without
printing records; optionally run the existing nonsecret verify.py through SSM and
require Success/0. Expected latest verified URL is http://54.159.81.113, but
automatic public IPs can change after stop/start. Stop and investigate a failed
check rather than redeploying or resetting data.

Stop/start, backup restore, retained-volume recovery, disaster recovery and schema
rollback remain untested. Monitoring/Actions gaps are documented for team review;
no additional feature implementation was included in this review.

### Final local submission checks

PASS: PowerShell source parsing; SSM failure/timeout and immutable-index tests;
Python compilation without writing cache files; all JSON parsing; release/evidence
consistency; deployed-script SHA-256 agreement; all seven README command blocks
parsed as PowerShell; proposed-file credential scan and manual review; whitespace
check. Scope: 14 Staging files in the full PR, 12 currently pending commit. No
credential redactions were needed. Live evidence was reused; no AWS operations
were performed during this submission review.