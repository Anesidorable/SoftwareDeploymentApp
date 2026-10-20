#!/bin/bash
# Runs ON the GitHub Actions runner. Sends shell commands to an EC2 instance through
# AWS Systems Manager, waits for them to finish, prints the output and fails if they failed.
#   ssm-run.sh <instance-id> <comment> <command> [command...]
set -euo pipefail
INSTANCE_ID=$1; COMMENT=$2; shift 2

PARAMS=$(jq -cn --args '{commands: $ARGS.positional, executionTimeout: ["1800"]}' "$@")
CMD_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --comment "${COMMENT:0:100}" \
  --parameters "$PARAMS" \
  --query Command.CommandId --output text)
echo "SSM command $CMD_ID sent to $INSTANCE_ID"

STATUS=Pending
for _ in $(seq 1 240); do
  sleep 5
  STATUS=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query Status --output text 2>/dev/null || echo Pending)
  case "$STATUS" in Success|Failed|Cancelled|TimedOut|Cancelling) break ;; esac
done

echo "----- output -----"
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query StandardOutputContent --output text || true
echo "----- errors -----"
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query StandardErrorContent --output text || true

if [ "$STATUS" != "Success" ]; then
  echo "::error::Remote command finished with status $STATUS"
  exit 1
fi
