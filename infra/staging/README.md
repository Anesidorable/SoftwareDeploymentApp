# Grocery Staging

This adds a separate Staging deployment. Existing Production workflows/template, the
Learner Lab stack, and instance test (i-02d58257bb276bbf5) are outside its scope.
No AWS resources have been created as part of preparing these files.

## Reviewed configuration

| Item | Value |
| --- | --- |
| Account / CLI profile | 245606545178 / learnerlab |
| EC2 / SSM / CloudFormation region | us-east-1 |
| Stack | grocery-staging |
| Instance profile / role | LabInstanceProfile / LabRole |
| VPC | vpc-0d06ded968993a487 |
| Subnet / AZ | subnet-0f01d6a2f0f1ae895 / us-east-1a |
| Internet route | main table rtb-071142d58cd677b3e -> igw-0f2b8ae43863c3d2b |
| Team registry | 960607644670.dkr.ecr.ap-southeast-2.amazonaws.com |
| ECR authentication region | ap-southeast-2 (independent of EC2 region) |
| Release | 8c6a325456f655a4820f7f13e8ce5c18a436fc4f |

LabInstanceProfile was inspected on 2026-10-20. LabRole has
AmazonSSMManagedInstanceCore and AmazonEC2ContainerRegistryReadOnly attached,
trusts EC2, and has no permissions boundary. Relevant AWS-managed policy documents
were inspected. Its lab-managed policy documents cannot be read by the operator.
IAM simulation allowed ssm:GetParameter, kms:Decrypt, ecr:GetAuthorizationToken,
ecr:BatchGetImage, ecr:GetDownloadUrlForLayer; operator iam:PassRole for LabRole
also simulated allowed. Simulation does not prove cross-account repository/key
policies or every lab restriction. The actual instance pull/decrypt must succeed.
No IAM resources or policy modifications are in this template.

## Release source and immutable images

The latest successful main push CI found during preparation is:
https://github.com/Anesidorable/SoftwareDeploymentApp/actions/runs/38702214896
(completed 2026-10-15). Both matrix jobs publish the same SHA tag to ECR and GHCR.
The checked-out HEAD matches that SHA.

release.json records these verified public GHCR mirror manifest digests:

- API: sha256:8471d1eb92aa7e0f504917c5055638afa36750613bfb601d50133efc9ca62375
- Web: sha256:47a09a9be2a9c15633c57c4fc1f428b92a9e5275182bdfb775ce2ff8c5795858
- Database: postgres:17@sha256:2d2b8998d31037bf721cfdf764d76ba74171b4fab3431b7f72c27c56ddbdf9e3

Both team manifests include linux/amd64. The deployment references are:

    960607644670.dkr.ecr.ap-southeast-2.amazonaws.com/app/api@sha256:8471d1eb92aa7e0f504917c5055638afa36750613bfb601d50133efc9ca62375
    960607644670.dkr.ecr.ap-southeast-2.amazonaws.com/app/web@sha256:47a09a9be2a9c15633c57c4fc1f428b92a9e5275182bdfb775ce2ff8c5795858

ECR digest equality is NOT yet verified: cross-account DescribeImages and
BatchGetImage were denied for both repositories because no resource policy allows
the operator. The script must verify the commit tag resolves to the locked digest
in each ECR repository and fetch each manifest BEFORE any CloudFormation mutation.
A mismatch is an error requiring review of release.json, never a silent update.
The instance pulls digest references, never latest. There is no build on EC2.
GHCR is used explicitly for local validation only; there is no deployment fallback.

### Precise registry-owner request (external blocker)

In account 960607644670, region ap-southeast-2, merge the statement in
registry-owner-policy.json into the EXISTING policies of BOTH app/api and app/web;
do not replace existing statements or disrupt teammate access.

Allow principals:
- arn:aws:iam::245606545178:role/LabRole (EC2 runtime pull)
- arn:aws:iam::245606545178:role/voclabs (operator preflight)

Actions: ecr:BatchGetImage, ecr:GetDownloadUrlForLayer,
ecr:BatchCheckLayerAvailability, ecr:DescribeImages.

Please confirm commit tag 8c6a325456f655a4820f7f13e8ce5c18a436fc4f is retained
on both repositories and resolves to the above digests. GetAuthorizationToken
is an identity permission in the consumer account, already present on LabRole;
it is not added to a repository resource policy.
AWS cross-account guidance:
https://docs.aws.amazon.com/AmazonECR/latest/userguide/repository-policy-examples.html

## Secret prerequisite (after deployment approval)

In the AWS console, select account 245606545178 and us-east-1, then Systems Manager
Parameter Store. Create /grocery/staging/db-password as Standard SecureString,
using the AWS-managed alias/aws/ssm key and a unique random password of at least
24 characters. Do not put it in a shell argument, Git, user data, stack parameter,
output, SSM command payload, transcript, screenshot or deployment log. No
parameter is created by this template or script. It is currently absent.

Do not share or reuse Testing/Production passwords. Line breaks/NUL are rejected.
Punctuation is supported: the API receives raw DB_PASSWORD plus DB_USER/DB_NAME/
DB_HOST/DB_PORT, allowing server/db.js and prisma.config.ts to apply their existing
encodeURIComponent(password) behavior. DATABASE_URL is deliberately omitted.

Only the instance fetches/decrypts the value. secrets.py writes a root-only tmpfs
password file and API env file under /run/grocery-staging. PostgreSQL uses
POSTGRES_PASSWORD_FILE; API receives the env file. Secret hydration runs before
Docker on reboot. No decrypted secret is returned through SSM. App/database
container logging is disabled to avoid connection strings in error logs; migration
output is suppressed for the same reason. Privileged host/Docker administrators
can inspect container environment and must be trusted. LabRole is shared and its
broad SSM permission does not provide IAM isolation from other trusted lab users.

Changing the parameter alone does not rotate an initialized PostgreSQL role.
Coordinate database ALTER ROLE, app restart and parameter update deliberately;
the deployment does not automatically rotate or reset passwords.

AWS SecureString guidance:
https://docs.aws.amazon.com/systems-manager/latest/userguide/secure-string-parameter-kms-encryption.html

## Resources and networking

The new stack creates one t3.small AL2023 x86_64 EC2 instance, its dedicated security
group, an encrypted 20 GiB gp3 root disk, an encrypted 20 GiB gp3 data volume and
data attachment. Existing VPC/subnet/internet gateway and LabInstanceProfile are
reused. No key pair, IAM role, S3 bucket, load balancer, EIP or RDS instance is
created. An automatically assigned public IPv4 address can change after stop/start.
Only TCP 80 is public by default; use -WebCidr to restrict it. This is HTTP Staging;
there is no TLS listener. SSM handles administration without SSH ingress.
Outbound internet access is needed for SSM, package installation, cross-region ECR
and Docker Hub PostgreSQL. Docker networks isolate service names, not host admins.

Only web publishes a host port (80 -> 8080). API uses HOST=0.0.0.0, PORT=5000,
APP_ENV=staging and GIT_SHA=<release>. Nginx gets API_UPSTREAM=api:5000. API and
PostgreSQL publish no host ports. The database name/user is grocery_staging.
A new security group and a Staging-only data volume prevent accidental reuse of
test/Testing/Production services or data.

## Validate and deploy from PowerShell 7

Open the confirmed checkout:

    Set-Location 'C:\Users\karaz\OneDrive\Desktop\Documents\GitHub\SoftwareDeploymentApp'

Run local parser/SSM failure tests:

    & .\infra\staging\Test-Staging.ps1

For disposable local Docker integration tests of the exact public CI mirrors:

    & .\infra\staging\Test-Staging.ps1 -Containers

This uses unique grocery-staging-check-* containers/network/volume and removes
only those resources afterward. It tests the actual migration, punctuation in a
fake password, frontend, proxy, database-backed API, and persistence after
recreating the database container. It does not prove EC2 bootstrap, EBS mounting,
SSM or cross-account ECR access.

Read-only AWS preflight:

    & .\infra\staging\Deploy-Staging.ps1 -ValidateOnly -Profile learnerlab -Region us-east-1 -StackName grocery-staging -VpcId vpc-0d06ded968993a487 -SubnetId subnet-0f01d6a2f0f1ae895 -AvailabilityZone us-east-1a -InstanceProfileName LabInstanceProfile -PasswordParameter /grocery/staging/db-password -ReleaseFile .\infra\staging\release.json

Expected currently: fail BEFORE creating resources, reporting missing SecureString
and denied ECR access. Metadata, account, IAM simulation, template and routing
checks still run. Credentials files are never opened or printed.

Exact deployment command, ONLY after approval and resolving prerequisites:

    & .\infra\staging\Deploy-Staging.ps1 -Profile learnerlab -Region us-east-1 -StackName grocery-staging -AwsCli 'C:\Program Files\Amazon\AWSCLIV2\aws.exe' -VpcId vpc-0d06ded968993a487 -SubnetId subnet-0f01d6a2f0f1ae895 -AvailabilityZone us-east-1a -InstanceProfileName LabInstanceProfile -PasswordParameter /grocery/staging/db-password -ReleaseFile .\infra\staging\release.json -WebCidr 0.0.0.0/0

The script validates identity, subnet/AZ/routing, profile role, relevant permissions,
secret metadata and both ECR digests before creating a change set. It permits only
the Staging stack name/account/region, requires Staging ownership on existing
stacks, rejects unexpected resource types/removals/replacements and never targets
a manually selected instance. AMI parameter changes can propose instance
replacement and will be rejected for manual review. First-boot UserData installs
Docker/Python; application deployment happens separately over SSM.

It waits for CloudFormation and SSM readiness, verifies instance ownership and
explicitly refuses the protected test ID. SSM runs only the scripts/configuration,
not credentials. It formats only the new expected EBS volume if blank, refuses
unexpected signatures/filesystems, mounts by UUID and orders Docker after mount
and secret hydration on future boots. Deployments are locked against concurrency.

Both images are pulled before replacing running services. PostgreSQL readiness is
required, then the app is stopped and a pre-migration pg_dump backup is saved.
The migration is npx --no-install prisma db migrate (the project's prisma db
migrate command, without a network installation fallback). API starts afterward
with node index.js, avoiding a duplicate implicit migration. Success requires
PostgreSQL readiness, matching API environment/release, a successful /api/list
database query, frontend HTTP 200 and the same checks through Nginx.

SSM Status must be Success AND ResponseCode zero. Terminal failures, remote
execution timeouts, local polling timeouts and API errors throw; no success or
release receipt is written. The script prints the command ID before polling.
If local polling times out, the remote command can still be running: inspect
that command before retrying. Logs are intentionally not dumped. A failure after
service replacement may leave Staging stopped and needs investigation; there is
no automatic schema rollback.

## Persistence, release history and rollback

PostgreSQL data lives at /srv/grocery-staging/postgres on the separate EBS volume.
It survives container recreation, reboot and instance termination. Docker startup
requires the mount so a missing data volume cannot silently initialize a root-disk
database. DataVolume has DeletionPolicy and UpdateReplacePolicy Retain: stack
deletion leaves the encrypted volume billable and must be cleaned up explicitly
after data review. Retention is not a backup, cross-AZ restore or automatic
reattachment plan. Recreating a deleted stack would create a NEW empty volume;
recover the retained volume manually in the same AZ first.

Pre-migration logical backups are root-only
/srv/grocery-staging/backups/<timestamp>.dump on that same volume, with no automatic
retention policy. Copy/snapshot them separately for protection from volume loss.
Restoring a backup is a manual, reviewed operation and loses later writes.

Successful release records with exact image refs, SHA and nonsecret config live at
/srv/grocery-staging/releases/<timestamp>.json and current.json. A local nonsecret
receipt is also written to the OS temporary directory. Back up receipts externally
if long-term audit retention is required. Failed deployments do not overwrite the
successful release record.

For an application rollback, review compatibility, create another release lock
with a previously recorded commit SHA and matching ECR digests and pass its path
with -ReleaseFile. Registry/account remain fixed and preflight verifies the old
tags still exist. Redeployment reruns migrations from the chosen image.
An older image may refuse or be incompatible with the newer schema; application
rollback does not reverse migrations. PostgreSQL major-version downgrade is not
supported; keep the pinned 17 image unless a separate migration plan is reviewed.
No automatic rollback promises database compatibility or preserves writes through
a manual restore.

## Preparation validation

See VALIDATION.md for the completed checks and remaining AWS runtime checks.
