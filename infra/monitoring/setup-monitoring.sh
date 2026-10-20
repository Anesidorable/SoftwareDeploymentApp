#!/bin/bash
# Installs the CloudWatch agent and an HTTP health probe. Safe to run on every deploy.
set -euo pipefail

TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)

# 1. CloudWatch agent: memory, disk and disk I/O (CPU and network come from EC2 itself)
rpm -q amazon-cloudwatch-agent >/dev/null || dnf install -y amazon-cloudwatch-agent
cat > /opt/aws/amazon-cloudwatch-agent/etc/cwagent.json <<'JSON'
{
  "agent": { "metrics_collection_interval": 60 },
  "metrics": {
    "namespace": "CWAgent",
    "append_dimensions": { "InstanceId": "${aws:InstanceId}" },
    "aggregation_dimensions": [["InstanceId"]],
    "metrics_collected": {
      "mem":    { "measurement": ["mem_used_percent"] },
      "disk":   { "measurement": ["used_percent"], "resources": ["/"] },
      "diskio": { "measurement": ["read_bytes", "write_bytes"] }
    }
  }
}
JSON
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/cwagent.json

# 2. Health probe: response time of /api/health every 60 seconds
mkdir -p /opt/monitoring
cat > /opt/monitoring/probe.sh <<PROBE
#!/bin/bash
TOKEN=\$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
ID=\$(curl -s -H "X-aws-ec2-metadata-token: \$TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
OUT=\$(curl -s -o /dev/null -m 5 -w '%{http_code} %{time_total}' http://localhost/api/health || echo "000 5")
CODE=\${OUT% *}; MS=\$(awk -v t="\${OUT#* }" 'BEGIN{printf "%d", t*1000}')
FAILED=0; [ "\$CODE" = "200" ] || FAILED=1
aws cloudwatch put-metric-data --region $REGION --namespace GroceryApp \
  --metric-data "MetricName=HealthLatencyMs,Value=\$MS,Unit=Milliseconds,Dimensions=[{Name=InstanceId,Value=\$ID}]" \
                "MetricName=HealthCheckFailed,Value=\$FAILED,Unit=Count,Dimensions=[{Name=InstanceId,Value=\$ID}]"
PROBE
chmod +x /opt/monitoring/probe.sh

cat > /etc/systemd/system/health-probe.service <<'UNIT'
[Unit]
Description=Publish /api/health latency to CloudWatch
[Service]
Type=oneshot
ExecStart=/opt/monitoring/probe.sh
UNIT
cat > /etc/systemd/system/health-probe.timer <<'UNIT'
[Unit]
Description=Run the health probe every minute
[Timer]
OnBootSec=60
OnUnitActiveSec=60
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now health-probe.timer
echo "Monitoring configured in $REGION"
