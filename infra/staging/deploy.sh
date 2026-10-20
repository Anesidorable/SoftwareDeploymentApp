#!/bin/bash
# Executed as root only on the instance returned by grocery-staging.
set -euo pipefail
umask 077
exec 9>/run/grocery-staging-deploy.lock
flock -n 9 || { echo "Another Staging deployment is running"; exit 1; }
trap 'echo "Staging deployment failed; no success recorded. Inspect configuration and service status without dumping secrets." >&2' ERR
cd /opt/grocery-staging
# Parse only validated, nonsecret config. No shell evaluation of JSON values.
readarray -t cfg < <(python3 - <<'PY'
import json
c=json.load(open("config.json"))
for key in ("volumeId","region","registryRegion","registry","api","web","postgres","release"):
    print(c[key])
PY
)
volume="${cfg[0]}"; region="${cfg[1]}"; registry_region="${cfg[2]}"
registry="${cfg[3]}"; api="${cfg[4]}"; web="${cfg[5]}"; postgres="${cfg[6]}"; release="${cfg[7]}"
# Match the exact EBS volume serial; never format an arbitrary /dev/nvme device.
device=""
for attempt in $(seq 1 60); do
  device=$(lsblk -dn -o PATH,SERIAL | awk -v id="${volume//-/}" '$2==id {print $1}')
  [ -n "$device" ] && break
  sleep 2
done
[ -b "$device" ] || { echo "Expected Staging EBS volume not found"; exit 1; }
fstype=$(blkid -s TYPE -o value "$device" || true)
if [ -z "$fstype" ]; then
  # Refuse a disk containing partitions or other signatures.
  [ "$(lsblk -nr "$device" | wc -l)" -eq 1 ]
  [ -z "$(wipefs -n --noheadings -o TYPE "$device")" ]
  mkfs.ext4 -q "$device"
elif [ "$fstype" != ext4 ]; then
  echo "Refusing unexpected data filesystem"; exit 1
fi
mkdir -p /srv/grocery-staging
uuid=$(blkid -s UUID -o value "$device")
if mountpoint -q /srv/grocery-staging; then
  [ "$(findmnt -n -o UUID --target /srv/grocery-staging)" = "$uuid" ]
else
  mount "$device" /srv/grocery-staging
fi
if ! grep -q "UUID=$uuid " /etc/fstab; then
  printf 'UUID=%s /srv/grocery-staging ext4 defaults,nofail,x-systemd.device-timeout=120 0 2\n' "$uuid" >> /etc/fstab
fi
mkdir -p /srv/grocery-staging/{postgres,releases,backups}
cat >/etc/systemd/system/grocery-staging-secrets.service <<'UNIT'
[Unit]
Description=Hydrate Staging secrets into root-only tmpfs
Wants=network-online.target
After=network-online.target
Before=docker.service
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/grocery-staging/secrets.py /opt/grocery-staging/config.json
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
mkdir -p /etc/systemd/system/docker.service.d
cat >/etc/systemd/system/docker.service.d/staging.conf <<'UNIT'
[Unit]
RequiresMountsFor=/srv/grocery-staging
Requires=grocery-staging-secrets.service
After=grocery-staging-secrets.service
UNIT
systemctl daemon-reload
systemctl enable grocery-staging-secrets.service >/dev/null
systemctl restart grocery-staging-secrets.service
export DOCKER_CONFIG
DOCKER_CONFIG=$(mktemp -d /run/grocery-staging-auth.XXXXXX)
trap 'rm -rf -- "$DOCKER_CONFIG"' EXIT
aws ecr get-login-password --region "$registry_region" |
  docker login --username AWS --password-stdin "$registry" >/dev/null 2>&1
# Verify all immutable images before stopping the previous app.
docker pull "$api" >/dev/null
docker pull "$web" >/dev/null
docker pull "$postgres" >/dev/null
docker network inspect grocery-staging >/dev/null 2>&1 || docker network create grocery-staging >/dev/null
docker rm -f staging-db >/dev/null 2>&1 || true
docker run -d --name staging-db --network grocery-staging --network-alias db \
  --restart unless-stopped --log-driver none \
  --mount type=bind,src=/srv/grocery-staging/postgres,dst=/var/lib/postgresql/data \
  --mount type=bind,src=/run/grocery-staging/db-password,dst=/run/secrets/db-password,readonly \
  -e POSTGRES_PASSWORD_FILE=/run/secrets/db-password \
  -e POSTGRES_USER=grocery_staging -e POSTGRES_DB=grocery_staging \
  "$postgres" >/dev/null
ready=0
for attempt in $(seq 1 60); do
  if docker exec staging-db pg_isready -U grocery_staging -d grocery_staging >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done
[ "$ready" -eq 1 ] || { echo "PostgreSQL readiness timed out"; exit 1; }
docker rm -f staging-web staging-api >/dev/null 2>&1 || true
stamp=$(date -u +%Y%m%dT%H%M%SZ)
docker exec staging-db pg_dump -U grocery_staging -d grocery_staging -Fc \
  >"/srv/grocery-staging/backups/$stamp.dump" 2>/dev/null
# Exact project migration; suppress errors that could contain a connection string.
if ! docker run --rm --network grocery-staging --log-driver none \
  --env-file /run/grocery-staging/api.env "$api" \
  npx --no-install prisma db migrate >/dev/null 2>&1; then
  echo "Prisma db migrate failed; Staging app remains stopped, backup retained"; exit 1
fi
docker run -d --name staging-api --network grocery-staging --network-alias api \
  --restart unless-stopped --log-driver none \
  --env-file /run/grocery-staging/api.env "$api" node index.js >/dev/null
healthy=0
for attempt in $(seq 1 60); do
  if docker exec staging-api node --input-type=module -e '
    const h=await fetch("http://127.0.0.1:5000/api/health");
    const j=await h.json();
    if(!h.ok||j.env!=="staging"||j.version!==process.env.GIT_SHA) process.exit(1);
    const d=await fetch("http://127.0.0.1:5000/api/list");
    if(!d.ok||!Array.isArray(await d.json())) process.exit(1);
  ' >/dev/null 2>&1; then healthy=1; break; fi
  sleep 2
done
[ "$healthy" -eq 1 ] || { echo "API/database health timed out"; exit 1; }
docker run -d --name staging-web --network grocery-staging --restart unless-stopped \
  -e API_UPSTREAM=api:5000 -p 80:8080 "$web" >/dev/null
python3 - <<'PY'
import json, time, urllib.request
for attempt in range(60):
    try:
        assert urllib.request.urlopen("http://127.0.0.1/", timeout=5).status == 200
        h=json.load(urllib.request.urlopen("http://127.0.0.1/api/health", timeout=5))
        assert h["env"]=="staging"
        assert isinstance(json.load(urllib.request.urlopen("http://127.0.0.1/api/list", timeout=5)), list)
        break
    except Exception:
        time.sleep(2)
else:
    raise SystemExit("Web proxy health timed out")
PY
cp config.json "/srv/grocery-staging/releases/$stamp.json"
cp config.json /srv/grocery-staging/releases/current.json
echo "Staging deployment successful: $release; database, API and web proxy verified."
