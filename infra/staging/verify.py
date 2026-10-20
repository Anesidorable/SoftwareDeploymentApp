"""Nonsecret verification of the exact Staging containers and data mount."""
import glob
import json
import os
import pathlib
import re
import subprocess
import time
import urllib.request

config = json.loads(pathlib.Path("/opt/grocery-staging/config.json").read_text())
def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL).strip()
def docker_field(name, field):
    return json.loads(run("docker", "inspect", "--format", "{{json " + field + "}}", name))
def get(path):
    with urllib.request.urlopen("http://127.0.0.1" + path, timeout=5) as response:
        assert response.status == 200
        return response.read()
report = {"release": config["release"], "containers": []}
for kind in ("db", "api", "web"):
    name = "staging-" + kind
    expected = config["postgres" if kind == "db" else kind]
    assert docker_field(name, ".Config.Image") == expected, "Unexpected container image reference"
    image = json.loads(run("docker", "image", "inspect", expected, "--format",
                          '{"id":{{json .Id}},"digests":{{json .RepoDigests}},"os":{{json .Os}},"arch":{{json .Architecture}}}'))
    assert image["os"] == "linux" and image["arch"] == "amd64"
    assert docker_field(name, ".Image") == image["id"], "Running image ID mismatch"
    canonical = expected.replace("docker.io/library/", "").split(":17@")
    if kind != "db":
        assert expected in image["digests"], "Running image missing selected registry digest"
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        state = docker_field(name, ".State")
        assert state["Running"], "Container is not running"
        if state.get("Health", {}).get("Status") == "healthy":
            break
        time.sleep(2)
    else:
        raise RuntimeError("Container health check did not become healthy")
    ports = docker_field(name, ".NetworkSettings.Ports") or {}
    if kind != "web":
        assert not any(ports.values()), "Internal service has published host ports"
    else:
        assert ports.get("8080/tcp") and all(p["HostPort"] == "80" for p in ports["8080/tcp"])
    report["containers"].append({"name": name, "image": expected,
                                 "imageId": image["id"], "health": "healthy",
                                 "restartCount": docker_field(name, ".RestartCount")})
mounts = docker_field("staging-db", ".Mounts")
assert any(m["Source"] == "/srv/grocery-staging/postgres" and
           m["Destination"] == "/var/lib/postgresql/data" for m in mounts)
assert run("findmnt", "-n", "-o", "FSTYPE", "--target", "/srv/grocery-staging") == "ext4"
assert os.path.ismount("/srv/grocery-staging")
report["dataMount"] = run("findmnt", "-n", "-o", "SOURCE,UUID", "--target", "/srv/grocery-staging")
assert run("docker", "exec", "staging-db", "pg_isready", "-U", "grocery_staging", "-d", "grocery_staging")
assert run("docker", "exec", "staging-db", "psql", "-U", "grocery_staging", "-d", "grocery_staging",
           "-At", "-v", "ON_ERROR_STOP=1", "-c", "SELECT 1") == "1"
html = get("/").decode()
health = json.loads(get("/api/health"))
assert health["env"] == "staging" and health["version"] == config["release"]
items = json.loads(get("/api/list"))
assert isinstance(items, list)
assets = re.findall(r'(?:src|href)="(/assets/[^"]+)"', html)
assert assets, "Frontend assets not referenced"
for path in assets:
    assert get(path)
backups = glob.glob("/srv/grocery-staging/backups/*.dump")
assert any(os.path.getsize(p) > 0 for p in backups), "No completed pre-migration backup"
assert run("systemctl", "is-active", "grocery-staging-secrets.service") == "active"
report.update(frontend="ok", frontendAssets=len(assets), api=health, databaseQuery="ok",
              databaseRows=len(items), preMigrationBackup="present",
              persistenceAfterReboot="not tested")
print(json.dumps(report, indent=2))
