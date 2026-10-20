# Preparation validation — 2026-10-20 (Australia/Sydney)

Checkout: C:\Users\karaz\OneDrive\Desktop\Documents\GitHub\SoftwareDeploymentApp
Branch: zidane/staging-environment
HEAD / selected release: 8c6a325456f655a4820f7f13e8ce5c18a436fc4f

- AWS cloudformation validate-template, learnerlab, us-east-1: PASS.
- cfn-lint, full resource/property schema validation: PASS (exit 0).
- PowerShell 7 parsing of all added .ps1/.psm1 files: PASS.
- Python compilation of secrets.py: PASS.
- Bash -n on deploy.sh: PASS.
- Test-Staging.ps1 SSM tests: PASS, including success/nonzero response, Failed,
  TimedOut, Cancelled, delivery/execution timeouts, local deadline expiration,
  initial InvocationDoesNotExist and InProgress.
- Test-Staging.ps1 -Containers: PASS using the exact pinned published public CI
  mirror manifests and pinned PostgreSQL image. Actual prisma db migrate succeeded;
  a fake password with URI-special characters authenticated using raw DB_PASSWORD;
  frontend, API release/env, database-backed /api/list and Nginx proxy succeeded.
  An inserted fixture survived PostgreSQL container recreation on the same volume.
  Disposable containers/network/volume were removed.
- Git whitespace check: PASS. Only new infra/staging files; no tracked file edits.
- IAM: inspected available profiles, LabRole trust and relevant AWS-managed
  policies. Simulation allowed SSM parameter read, KMS decrypt, ECR auth/pull and
  operator PassRole. Lab-managed policy document reads were denied; no IAM edits.
- Deploy-Staging.ps1 -ValidateOnly: EXPECTED FAILURE before any mutation.
  Account/template/network/profile/identity simulation passed. Blockers:
  /grocery/staging/db-password SecureString absent; both ECR repositories deny
  DescribeImages. Separate BatchGetImage probes were also denied.
- ECR digests have NOT been verified. release.json digests were independently
  verified in anonymous GHCR mirror manifests for the successful main CI SHA.
  Deployment preflight must prove equality in ECR; no fallback is implemented.
- Final read-only EC2/CloudFormation checks returned only the existing running
  test instance i-02d58257bb276bbf5 and CREATE_COMPLETE Learner Lab stack.
  No AWS resource creation, updates, SSM remote commands, pushes or merges ran.

Not yet exercised: real AL2023 EC2 bootstrap, EBS attachment/mount/reboot ordering,
instance-side SecureString decryption, cross-account ECR pulling as LabRole, and
CloudFormation change-set execution. These require an approved deployment after
the registry-owner request and secret prerequisite are completed.
