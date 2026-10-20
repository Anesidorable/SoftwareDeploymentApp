#!/bin/bash
# Runs ON the EC2 instance (as root, via AWS Systems Manager Run Command).
#
#   deploy.sh deploy   <env> <git-sha> <api-image@digest> <web-image@digest> <compose-url>
#   deploy.sh rollback <env>
#
# deploy:   pulls the exact image digests, (testing only) starts from an empty database,
#           (production only) backs up the database first, replaces the containers and waits
#           until /api/health reports the database connected and the expected version.
# rollback: puts the previous release's digests back and waits for it to become healthy.
set -euo pipefail

ACTION=${1:?action required}
ENV_NAME=${2:?environment required}
DIR=/opt/grocery
COMPOSE="docker compose --project-directory $DIR -f $DIR/docker-compose.release.yml --env-file $DIR/.env"
mkdir -p "$DIR/backups" "$DIR/releases"
cd "$DIR"

exec 9>/run/grocery-deploy.lock
flock -n 9 || { echo "Another deployment is already running"; exit 1; }

imds() {
  local token
  token=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
  curl -s -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$1"
}
REGION=$(imds placement/region)

ecr_login() {
  local registry=${1%%/*}
  aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$registry" >/dev/null
}

# Database password: SecureString in Parameter Store, generated on the first deployment.
db_password() {
  local name="/grocery/$ENV_NAME/db-password" value
  if ! value=$(aws ssm get-parameter --region "$REGION" --name "$name" --with-decryption \
      --query Parameter.Value --output text 2>/dev/null); then
    value=$(openssl rand -hex 24)
    aws ssm put-parameter --region "$REGION" --name "$name" --type SecureString --value "$value" >/dev/null
    echo "Created $name in Parameter Store" >&2
  fi
  printf '%s' "$value"
}

write_env() { # api web sha build_time
  umask 077
  cat > "$DIR/.env" <<ENVFILE
API_IMAGE=$1
WEB_IMAGE=$2
GIT_SHA=$3
BUILD_TIME=$4
APP_ENV=$ENV_NAME
DB_PASSWORD=$(db_password)
ENVFILE
}

wait_healthy() { # expected sha
  local expected=$1 body
  for _ in $(seq 1 30); do
    body=$(curl -s -m 3 http://localhost/api/health || true)
    if [[ $body == *'"database":"connected"'* && $body == *"\"version\":\"$expected\""* ]]; then
      echo "Healthy: $body"
      return 0
    fi
    sleep 3
  done
  echo "Not healthy after 90s. Last response: ${body:-none}" >&2
  $COMPOSE ps >&2 || true
  $COMPOSE logs --tail 40 api >&2 || true
  return 1
}

case "$ACTION" in
  deploy)
    SHA=${3:?sha}; API_IMAGE=${4:?api image}; WEB_IMAGE=${5:?web image}; COMPOSE_URL=${6:?compose url}
    echo "== Deploying ${SHA:0:7} to $ENV_NAME"
    curl -fsSL "$COMPOSE_URL" -o "$DIR/docker-compose.release.yml"
    ecr_login "$API_IMAGE"
    docker pull -q "$API_IMAGE"
    docker pull -q "$WEB_IMAGE"

    # Keep the running release so it can be restored.
    [ -f "$DIR/releases/current.env" ] && cp "$DIR/releases/current.env" "$DIR/releases/previous.env"

    if [ "$ENV_NAME" = testing ] && [ -f "$DIR/.env" ]; then
      echo "Testing: removing the old database so tests start clean"
      $COMPOSE down -v --remove-orphans || true
    fi

    if [ "$ENV_NAME" = production ] && docker ps --format '{{.Names}}' | grep -qx db; then
      BACKUP="$DIR/backups/pre-${SHA:0:7}-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
      docker exec db pg_dump -U app myapp | gzip > "$BACKUP"
      echo "Database backup: $BACKUP ($(du -h "$BACKUP" | cut -f1))"
      ls -1t "$DIR"/backups/*.sql.gz | tail -n +6 | xargs -r rm -f   # keep the 5 newest
    fi

    write_env "$API_IMAGE" "$WEB_IMAGE" "$SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    $COMPOSE up -d --remove-orphans
    wait_healthy "$SHA"
    printf 'API_IMAGE=%s\nWEB_IMAGE=%s\nGIT_SHA=%s\n' "$API_IMAGE" "$WEB_IMAGE" "$SHA" > "$DIR/releases/current.env"
    docker image prune -af --filter "until=72h" >/dev/null || true
    echo "== Deployed ${SHA:0:7} to $ENV_NAME"
    ;;

  rollback)
    [ -f "$DIR/releases/previous.env" ] || { echo "No previous release to roll back to" >&2; exit 1; }
    # shellcheck disable=SC1091
    source "$DIR/releases/previous.env"
    echo "== Rolling $ENV_NAME back to ${GIT_SHA:0:7}"
    ecr_login "$API_IMAGE"
    write_env "$API_IMAGE" "$WEB_IMAGE" "$GIT_SHA" "rollback-$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    $COMPOSE up -d --remove-orphans
    wait_healthy "$GIT_SHA"
    cp "$DIR/releases/previous.env" "$DIR/releases/current.env"
    echo "== Rolled back to ${GIT_SHA:0:7}"
    ;;

  *)
    echo "Unknown action: $ACTION" >&2; exit 2 ;;
esac
