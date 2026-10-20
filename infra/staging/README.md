# Grocery Staging

This deployment targets only account 245606545178, us-east-1, stack grocery-staging.
It reuses LabInstanceProfile / LabRole without modifying IAM. Testing, Production,
the Learner Lab stack and test instance i-02d58257bb276bbf5 are outside its scope.

## Deliberately selected release — 2026-10-20

Selected commit: 2aa5022552b88094760cee0bc76a7ecfb2163448
CI: https://github.com/Anesidorable/SoftwareDeploymentApp/actions/runs/39379318432
Registry: 960607644670.dkr.ecr.us-east-1.amazonaws.com
ECR authentication region: us-east-1.

The user explicitly approved this newer release because the previous locked
indexes (commit 8c6a325456f655a4820f7f13e8ce5c18a436fc4f) were absent in Virginia.
Both available Virginia indexes exactly matched GHCR commit-tagged mirrors for
the newer release. Both SLSA v1 statements identified that commit/repository and
CI run 39379318432, whose API and web push jobs succeeded. No images were rebuilt.
Signatures were not independently verified; resolved dependency provenance is
incomplete. The copy operation itself was not audited.

release.json records both selections and the reason. Current immutable indexes:

- API: sha256:02d7d6e7a8f3fd5ba5f4742af3bc84a30377dad61c04e012510ae3857a843c2e
- Web: sha256:7be399dd5f76166f3432c0ef26bb827b5513cfdf2be1ab4ecb721334aee90e59

Locked linux/amd64 runtime manifests:

- API: sha256:dca7bf8f37b3f4b052e91ce082596052bc666d434172e6c1377ba53581d3b994
- Web: sha256:31dcaca5d85d08729ea91438fa272c23411b96ea9c0361189e309cba0ab5cb43

PostgreSQL remains postgres:17@sha256:2d2b8998d31037bf721cfdf764d76ba74171b4fab3431b7f72c27c56ddbdf9e3.

Virginia currently has no commit-SHA tags. Neither preflight nor deployment
requires a tag: DescribeImages and BatchGetImage use imageDigest. Preflight checks
the returned digest, hashes the exact index bytes, validates the selected
linux/amd64 descriptor and verifies that child manifest exists. Runtime pulls use
registry/repository@sha256 references only. There is no latest or registry fallback.

## Relevant old/new release changes

There are no server, Prisma migration/schema, database configuration or server
Dockerfile changes between the selected commits. The API runtime digest is
identical; index/attestation metadata changed. The web runtime changed because its
Nginx configuration adds a response-timing access log.

Other release changes add Production monitoring, alarms and monitoring setup.
Staging does not run the Production deployment workflow or monitoring installer,
does not create their resources and does not change those files.

## Infrastructure and secrets

The Staging template creates one t3.small AL2023 x86_64 instance, a dedicated
security group, encrypted 20 GiB root disk and a retained encrypted 20 GiB gp3 data
volume with attachment. It uses VPC vpc-0d06ded968993a487 and public subnet
subnet-0f01d6a2f0f1ae895 in us-east-1a. No IAM roles, SSH key, EIP, load balancer,
S3 bucket or RDS instance is created. Public IP may change after stop/start.

Only TCP 80 is public (HTTP); -WebCidr can restrict clients. SSM provides
administration. API and DB have no published host ports. The internal Docker
network provides aliases api and db; Nginx uses API_UPSTREAM=api:5000. API uses
HOST=0.0.0.0, PORT=5000, APP_ENV=staging and the selected GIT_SHA.
Outbound access is required for SSM, packages, Virginia ECR and Docker Hub.

The existing /grocery/staging/db-password must be a SecureString in us-east-1,
encrypted with alias/aws/ssm. Preflight reads metadata only. Only the instance
decrypts it; values never appear in Git, user data, outputs, SSM command payloads
or deployment logs. Root-only /run/grocery-staging files hold the transient
password and API environment; PostgreSQL uses POSTGRES_PASSWORD_FILE.
The API receives raw DB_PASSWORD and DB_USER/DB_NAME/DB_HOST/DB_PORT, preserving
the application's encodeURIComponent(password) behavior. DATABASE_URL is omitted.
Passwords require 24+ characters without CR, LF or NUL.

Secret hydration runs before Docker on reboot. Privileged host/Docker operators
remain trusted because they can inspect container environment. LabRole is shared;
this does not provide IAM isolation from other trusted lab users. API/database
logs and migration output are suppressed to avoid connection strings in logs.

Do not rotate an initialized database by changing only the parameter: coordinate
ALTER ROLE, parameter update and application restart. Deployment never resets DB
passwords or deletes existing Staging data.

## Cross-account permissions

The operator voclabs needs DescribeImages and BatchGetImage on both Virginia
repositories. LabRole needs GetAuthorizationToken on resource *, plus the pull
actions BatchGetImage, GetDownloadUrlForLayer and BatchCheckLayerAvailability on
both repositories. IAM simulation includes explicit aws:RequestedRegion=us-east-1.
Identity simulations do not prove cross-account repository access.

registry-owner-policy.json is an example to MERGE into each repository's existing
policy in account 960607644670, us-east-1. Preserve teammate grants. This local file
is not applied by deployment. No lab-managed roles are modified.

## Regional SCP restriction and resolution

Earlier read-only simulations tested both voclabs and LabRole against the actual
Sydney app/api and app/web ARNs. With all other inputs unchanged, the four ECR
repository actions and separate GetAuthorizationToken action returned explicitDeny
for aws:RequestedRegion=ap-southeast-2 and allowed for us-east-1. The full responses
reported AllowedByOrganizations=false for Sydney and true for Virginia. Account
SCP listing and lab-managed policy-document reads were denied, so the exact SCP
name/clause could not be inspected. LabRole's AWS-managed ECR read policy was
readable; that Allow did not override the organization restriction.

The registry owner made a coherent newer published release available in Virginia.
The user explicitly selected it, and Staging then passed exact digest reads and
actual instance-side pulls in us-east-1. This resolved the required image-access
path without changing lab-managed IAM or the SCP. It does not mean the Sydney
restriction was removed. Changing simulation context alone neither moved the
repositories nor proved access to another registry.

## Implemented, verified and missing features

| Capability | Implemented/configured | Verification or limit |
| --- | --- | --- |
| Immutable release deployment | Manual PowerShell + SSM, Virginia digest lock, existing LabInstanceProfile | Live deployment Success/0; exact images verified |
| Health checks | Docker DB/API/web probes and manual verify.py | Healthy containers and frontend/proxy/API/database checks passed |
| Persistence | Retained encrypted EBS, UUID mount, Docker startup dependencies, secret hydration | Record survived DB container recreation and controlled reboot; cleaned up |
| Performance monitoring | No Staging agent, custom performance metrics, alarms, dashboard, alerting or load-test baseline configured by this contribution | Docker health checks verify availability, not performance; no monitoring-stack runtime verification was performed |
| Basic EC2 metrics | Staging template leaves AWS basic-monitoring defaults; no explicit detailed-monitoring setting | Available AWS defaults are not a configured or verified Staging performance-monitoring solution |
| Logs | Web image has Nginx timing access logs; API/DB logs and migration output are suppressed to protect connection strings | No Staging centralized log collection or alerts configured |
| Automated Staging deployment | No GitHub Actions Staging workflow or automatic Virginia promotion | Deployment uses learnerlab locally; no GitHub Staging environment/OIDC integration added |

Docker restart-unless-stopped handles process/daemon restarts; an unhealthy Docker
health status alone does not restart a container. No extra monitoring or CI/CD
features were implemented during submission review.

The selected release includes separate Production monitoring changes on main.
Those scripts/resources are not invoked by the Staging deployment. Their presence
in main does not make Staging monitored.

## Expected GitHub Actions behavior for this PR

Reviewed public main at 2aa5022552b88094760cee0bc76a7ecfb2163448 on 2026-10-20.
This PR changes only infra/staging; workflow files are not changed.

| Event | Lint | Build Docker Image | Deploy To Production |
| --- | --- | --- | --- |
| Open/update this PR targeting main | Runs: pull_request has no path filter | Not triggered: PR paths require server/** or client/** | No deployment from this PR |
| Merge this Staging-only PR into main | Not triggered by push: requires client/** | Not triggered by push: requires server/**, client/** or .github/workflows/** | No qualifying build completion caused by this merge, so no deployment |
| Later matching application/workflow changes on main | Lint runs for client changes | Builds and publishes GHCR + existing Sydney ECR images | Successful qualifying push build can trigger existing Production deployment |

These are conclusions from the checked workflow definitions and proposed paths,
not a claim that future workflows cannot change. Unrelated builds, manual
workflow_dispatch, branch-protection requirements and repository rules are outside
this PR's trigger analysis. Required-check settings were not inspected. CI still
publishes to Sydney ECR; the owner-provided Virginia copy is not automated here.
No Staging deployment or automated Staging validation is added to Actions.

## Before the demo — 21 October 2026 (Australia/Sydney)

Live results in VALIDATION.md are historical evidence, not a guarantee that the
Learner Lab remains running tomorrow. Check the instance and its current IP before
opening the demo. An automatic public IPv4 address can change after stop/start;
use the actual current instance IP rather than only a saved URL.

Use PowerShell 7.4 or newer (submission checks used 7.6.5), AWS CLI v2 and the
learnerlab profile. Refresh an expired Learner Lab session through its normal
sign-in process without putting credentials in Git, transcripts or messages.

    Set-Location 'C:\Users\karaz\OneDrive\Desktop\Documents\GitHub\SoftwareDeploymentApp'
    $aws = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'
    & $aws sts get-caller-identity --profile learnerlab --region us-east-1 --query Account --output text --no-cli-pager
    & $aws cloudformation describe-stacks --stack-name grocery-staging --profile learnerlab --region us-east-1 --query 'Stacks[0].{Status:StackStatus,Outputs:Outputs}' --output json --no-cli-pager
    & $aws ec2 describe-instances --instance-ids i-00e4de616bb12dc49 --profile learnerlab --region us-east-1 --query 'Reservations[0].Instances[0].{Id:InstanceId,State:State.Name,IP:PublicIpAddress}' --output json --no-cli-pager
    & $aws ec2 describe-instance-status --instance-ids i-00e4de616bb12dc49 --include-all-instances --profile learnerlab --region us-east-1 --query 'InstanceStatuses[].{Id:InstanceId,State:InstanceState.Name,System:SystemStatus.Status,Instance:InstanceStatus.Status}' --output json --no-cli-pager
    & $aws ssm describe-instance-information --filters Key=InstanceIds,Values=i-00e4de616bb12dc49 --profile learnerlab --region us-east-1 --query 'InstanceInformationList[].{Id:InstanceId,Ping:PingStatus}' --output json --no-cli-pager

Expected account: 245606545178. Confirm the stack still names the expected
instance/data volume, instance is running, EC2 status checks are ok and SSM is
Online. Stop if identity or resource IDs differ. If the lab stopped the instance,
follow the lab's authorized startup procedure and recheck; do not replace/wipe
resources or assume the untested stop/start cycle behaves exactly like reboot.

Derive the URL and check only nonsecret responses:

    $stagingIp = & $aws ec2 describe-instances --instance-ids i-00e4de616bb12dc49 --profile learnerlab --region us-east-1 --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --no-cli-pager
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($stagingIp) -or $stagingIp -eq 'None') { throw 'Current Staging IP unavailable' }
    $stagingUrl = 'http://' + $stagingIp.Trim()
    $releaseLock = Get-Content .\infra\staging\release.json -Raw | ConvertFrom-Json
    $stagingHome = Invoke-WebRequest -Uri ($stagingUrl + '/') -TimeoutSec 15
    $stagingHealth = Invoke-RestMethod -Uri ($stagingUrl + '/api/health') -TimeoutSec 15
    $stagingRows = Invoke-RestMethod -Uri ($stagingUrl + '/api/list') -TimeoutSec 15
    if ($stagingHome.StatusCode -ne 200 -or $stagingHealth.env -ne 'staging' -or $stagingHealth.version -ne $releaseLock.release) { throw 'Staging verification failed' }
    [pscustomobject]@{Url=$stagingUrl;HttpStatus=$stagingHome.StatusCode;Environment=$stagingHealth.env;Release=$stagingHealth.version;DatabaseRows=@($stagingRows).Count}

For container/mount/digest checks, use Systems Manager Run Command with
AWS-RunShellScript, targeting only i-00e4de616bb12dc49, and run:

    python3 /opt/grocery-staging/verify.py

Wait for terminal Status=Success and ResponseCode=0 and inspect its sanitized
report. It checks health, mounted storage, digests and application/database
connectivity. Its standalone persistence field is not a fresh reboot test;
use the separate recorded persistence evidence.

These demo checks do not require redeployment, migration, record insertion,
container recreation or reboot. Existing live evidence covers those operations.
If a check fails, stop and investigate before the presentation; preserve the
instance and data volume. Check the fresh URL in the browser shortly before
presenting and keep the validation evidence available as a backup demonstration.

## Commands — PowerShell 7

    Set-Location 'C:\Users\karaz\OneDrive\Desktop\Documents\GitHub\SoftwareDeploymentApp'
    & .\infra\staging\Test-Staging.ps1
    & .\infra\staging\Test-Staging.ps1 -Containers
    & .\infra\staging\Deploy-Staging.ps1 -ValidateOnly -Profile learnerlab -Region us-east-1 -StackName grocery-staging

Container tests use exact selected GHCR mirror digests explicitly for disposable
local validation only. They verify the real Prisma migration, special-character
fixture password, frontend/proxy/API/database, DB container recreation persistence
and migration rerun with existing fixture data. Unique test resources are removed;
real Staging data is not touched.

Authorized deployment:

    & .\infra\staging\Deploy-Staging.ps1 -Profile learnerlab -Region us-east-1 -StackName grocery-staging -AwsCli 'C:\Program Files\Amazon\AWSCLIV2\aws.exe' -VpcId vpc-0d06ded968993a487 -SubnetId subnet-0f01d6a2f0f1ae895 -AvailabilityZone us-east-1a -InstanceProfileName LabInstanceProfile -PasswordParameter /grocery/staging/db-password -ReleaseFile .\infra\staging\release.json -WebCidr 0.0.0.0/0

All prerequisites run before mutations. The script scopes changes to the exact
account/region/stack, verifies Staging ownership, rejects resource removals or
replacements, and refuses the protected test instance. A changed AMI resolution
can propose replacement and will stop deployment for separate review.

It waits for stack completion and SSM readiness. SSM executes the nonsecret
scripts/config only, with concurrency locks. EBS formatting requires the expected
blank volume serial; unexpected signatures or filesystems are rejected. Mounts
use UUID, and Docker requires the mount and secret hydration on future boots.

All images are pulled before service replacement. After DB readiness, the app
is quiesced and a pre-migration pg_dump backup is saved. The real migration is
npx --no-install prisma db migrate. API starts with node index.js afterward to
avoid running migration twice. Docker health checks are installed for all three
containers. verify.py requires healthy containers, exact configured digest refs
and running image IDs, linux/amd64, internal API/DB ports, the EBS mount, a database
query, exact API release/environment, frontend HTML/assets, /api/list through Nginx
and a nonempty backup.

Success requires actual SSM Status=Success AND ResponseCode=0. API errors,
nonzero exit codes and timeouts fail deployment and do not write a success
receipt. A local timeout may leave the remote command running; inspect that
command before retrying. Failed service replacement may leave Staging stopped.
No automatic schema rollback occurs.

For a later nonsecret runtime check, run on this Staging instance through SSM:

    python3 /opt/grocery-staging/verify.py

Wait for command completion and require Success/0 as for deployment. Do not dump
container environment, secret files or unsanitized migration/application logs.
External HTTP checks should verify the reported WebUrl, /api/health and /api/list.

## Persistence, backup and rollback limits

Data is /srv/grocery-staging/postgres on separate encrypted EBS. It survives
container replacement; mount ordering is designed to protect reboot startup.
Only behavior actually exercised is recorded in VALIDATION.md.

DeletionPolicy/UpdateReplacePolicy Retain leaves the EBS volume billable after
stack deletion. Retention is not backup or automatic recovery/reattachment. A
new stack after deletion creates a new empty volume; recover retained data
manually in its AZ first. Never format or replace a retained data volume to retry.

Pre-migration backups are root-only /srv/grocery-staging/backups/<timestamp>.dump
on the SAME volume. There is no automatic backup retention or off-volume copy.
A reviewed restore loses later writes; protect against volume loss separately.

Successful releases are recorded under /srv/grocery-staging/releases and a local
nonsecret receipt in the OS temporary directory. Failed deployments do not
overwrite the successful current record.

Rollback requires an explicitly reviewed release lock with retained digest
images. It reruns that image's migration command and may fail against a newer
schema. Application rollback does not reverse migrations. PostgreSQL remains
pinned to major 17; downgrading database versions is not a rollback mechanism.

## Current deployment state — 2026-10-20

Staging is live at http://54.159.81.113 on instance i-00e4de616bb12dc49.
The original data volume vol-0669434c058070f39 and ext4 UUID were retained without
formatting. Secret version 2 passed hydration; the resumed deployment succeeded.
All containers, immutable digests, migrations, frontend/assets/proxy/API/database
connectivity, live DB container-recreation persistence and controlled reboot
persistence passed. The temporary test record was removed.

See VALIDATION.md and verification-evidence.json for sanitized command IDs,
terminal status/response codes, hashes, boot IDs and remaining test limits.


## Resume an existing filesystem safely

After inspecting the instance and data disk, use the explicit resume command:

    & .\infra\staging\Deploy-Staging.ps1 -ResumeExisting -ExpectedInstanceId i-00e4de616bb12dc49 -ExpectedVolumeId vol-0669434c058070f39 -ExpectedFilesystemUuid 8402756a-0f61-4f56-88ba-cb6efb1e3ded -Profile learnerlab -Region us-east-1 -StackName grocery-staging

Add -ValidateOnly for read-only prerequisites. ResumeExisting requires the exact
existing stack outputs and filesystem UUID. It does not create a CloudFormation
change set. The runtime requires an existing ext4 filesystem with that UUID and
does not enter the blank-disk initialization path.

Local edits are not automatically present on EC2. Deployment transfers deploy.sh,
secrets.py, verify.py and nonsecret config.json through SSM and verifies each
transferred SHA-256 before executing. The corrected wipefs --output inspection is
retained for new deployments; a resumed deployment never formats a disk.
After hydration succeeds it explicitly starts Docker, which may be inactive
after a previous failed secret-service dependency.

persistence-check.py provides phased, Staging-only live validation: seed,
recreate, after-reboot and cleanup. It asserts the expected data volume/UUID,
uses a unique temporary record, recreates only staging-db while preserving its
bind mount, checks a changed boot ID and removes only its own record. Its state
and nonsecret result are stored on the Staging data volume. It must be explicitly
uploaded/hash-checked before running; deployment does not run persistence tests
or reboot automatically. A controlled reboot is a separate authorized action.
