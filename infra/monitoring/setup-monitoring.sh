#!/bin/bash
# Production monitoring (Project Brief 4.1 / 5.1). Runs over SSM after every deploy and is safe to re-run.
#  - CloudWatch agent: memory, disk, disk I/O, and the api/web container logs
#  - Probe every 60 s: /api/health response time and status, HTTP 5xx count and p95 request latency
set -euo pipefail

TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
LOG_GROUP=/grocery/production/containers

# 1. CloudWatch agent (CPU and network come from EC2's own metrics)
rpm -q amazon-cloudwatch-agent >/dev/null || dnf install -y amazon-cloudwatch-agent

# Container IDs change on every deploy, so the log file paths are rebuilt each run
LOG_FILES=""
for c in api web; do
  id=$(docker inspect -f '{{.Id}}' "$c" 2>/dev/null || true)
  [ -n "$id" ] || continue
  [ -n "$LOG_FILES" ] && LOG_FILES="$LOG_FILES,"
  LOG_FILES="$LOG_FILES
          { \"file_path\": \"/var/lib/docker/containers/$id/$id-json.log\", \"log_group_name\": \"$LOG_GROUP\", \"log_stream_name\": \"$c\" }"
done

LOGS_BLOCK=""
if [ -n "$LOG_FILES" ]; then
  LOGS_BLOCK=",
  \"logs\": { \"logs_collected\": { \"files\": { \"collect_list\": [$LOG_FILES
  ] } } }"
fi

cat > /opt/aws/amazon-cloudwatch-agent/etc/cwagent.json <<JSON
{
  "agent": { "metrics_collection_interval": 60 },
  "metrics": {
    "namespace": "CWAgent",
    "append_dimensions": { "InstanceId": "\${aws:InstanceId}" },
    "aggregation_dimensions": [["InstanceId"]],
    "metrics_collected": {
      "mem":    { "measurement": ["mem_used_percent"] },
      "disk":   { "measurement": ["used_percent"], "resources": ["/"] },
      "diskio": { "measurement": ["read_bytes", "write_bytes"] }
    }
  }$LOGS_BLOCK
}
JSON
python3 -m json.tool /opt/aws/amazon-cloudwatch-agent/etc/cwagent.json >/dev/null
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/cwagent.json

# 2. Probe, run every minute by a systemd timer
mkdir -p /opt/monitoring
cat > /opt/monitoring/probe.sh <<'PROBE'
#!/bin/bash
set -uo pipefail
TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
MD="curl -s -H X-aws-ec2-metadata-token:$TOKEN http://169.254.169.254/latest/meta-data"
ID=$($MD/instance-id); REGION=$($MD/placement/region)
DIM="Dimensions=[{Name=InstanceId,Value=$ID}]"

# Health check: status code and response time
OUT=$(curl -s -o /dev/null -m 5 -w '%{http_code} %{time_total}' http://localhost/api/health || echo "000 5")
CODE=${OUT% *}
HEALTH_MS=$(awk -v t="${OUT#* }" 'BEGIN { printf "%d", t * 1000 }')
FAILED=0; [ "$CODE" = "200" ] || FAILED=1

# Last minute of Nginx access log lines: '"GET /x HTTP/1.1" 200 512 rt=0.004'
LINES=$(docker logs --since 60s web 2>&1 | grep -oE '" [0-9]{3} [0-9]+ rt=[0-9.]+' || true)
COUNT_5XX=$(printf '%s\n' "$LINES" | awk '$2 ~ /^5/ { n++ } END { print n + 0 }')
P95_MS=$(printf '%s\n' "$LINES" | awk -F'rt=' 'NF > 1 { printf "%d\n", $2 * 1000 }' | sort -n |
  awk '{ v[NR] = $1 } END { if (NR > 0) { i = int(NR * 0.95); if (i < NR * 0.95) i++; if (i < 1) i = 1; print v[i] } }')

DATA=("MetricName=HealthLatencyMs,Value=$HEALTH_MS,Unit=Milliseconds,$DIM"
      "MetricName=HealthCheckFailed,Value=$FAILED,Unit=Count,$DIM"
      "MetricName=Http5xxCount,Value=$COUNT_5XX,Unit=Count,$DIM")
[ -n "$P95_MS" ] && DATA+=("MetricName=RequestLatencyP95Ms,Value=$P95_MS,Unit=Milliseconds,$DIM")

aws cloudwatch put-metric-data --region "$REGION" --namespace GroceryApp --metric-data "${DATA[@]}"
PROBE
chmod +x /opt/monitoring/probe.sh

cat > /etc/systemd/system/health-probe.service <<'UNIT'
[Unit]
Description=Publish health, 5xx and latency metrics to CloudWatch
[Service]
Type=oneshot
ExecStart=/opt/monitoring/probe.sh
UNIT
cat > /etc/systemd/system/health-probe.timer <<'UNIT'
[Unit]
Description=Run the monitoring probe every minute
[Timer]
OnBootSec=60
OnUnitActiveSec=60
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now health-probe.timer
echo "Monitoring configured in $REGION"
