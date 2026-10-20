"""Authorized Staging-only persistence exercise; never reads or prints passwords."""
import fcntl
import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.request
import uuid

os.umask(0o077)
lock = open("/run/grocery-staging-deploy.lock", "w")
fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
config = json.loads(pathlib.Path("/opt/grocery-staging/config.json").read_text())
assert config["volumeId"] == "vol-0669434c058070f39"
assert config["existingFilesystemUuid"] == "8402756a-0f61-4f56-88ba-cb6efb1e3ded"
state_path = pathlib.Path("/srv/grocery-staging/persistence-validation.json")
def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL).strip()
def sql(query):
    return subprocess.check_output(
        ["docker", "exec", "-i", "staging-db", "psql", "-U", "grocery_staging",
         "-d", "grocery_staging", "-At", "-v", "ON_ERROR_STOP=1", "-q"],
        input=query, text=True, stderr=subprocess.DEVNULL).strip()
def boot_id():
    return pathlib.Path("/proc/sys/kernel/random/boot_id").read_text().strip()
def inspect(container, field):
    return json.loads(run("docker", "inspect", "--format", "{{json "+field+"}}", container))
def verify():
    subprocess.run(["python3", "/opt/grocery-staging/verify.py"], check=True)
def api_has(state):
    with urllib.request.urlopen("http://127.0.0.1/api/list", timeout=5) as response:
        rows=json.load(response)
    return any(row["id"] == state["id"] and row["item"] == state["marker"] for row in rows)
def mounted():
    assert os.path.ismount("/srv/grocery-staging")
    assert run("findmnt","-n","-o","UUID","--target","/srv/grocery-staging") == config["existingFilesystemUuid"]

mounted()
action=sys.argv[1]
if action=="seed":
    assert not state_path.exists(), "Prior validation state exists; investigate before adding another record"
    verify()
    marker="codex-staging-persistence-"+uuid.uuid4().hex
    row_id=int(sql('INSERT INTO "GroceryList" (item,count,notes,ticked) VALUES '
                   "('"+marker+"',1,'Temporary authorized staging persistence check',false) RETURNING id;"))
    state={"id":row_id,"marker":marker,"bootBefore":boot_id(),
           "uuid":config["existingFilesystemUuid"],"oldDbContainerId":inspect("staging-db",".Id")}
    state_path.write_text(json.dumps(state,indent=2))
    assert api_has(state), "Test record not visible through API"
    print(json.dumps({"phase":"seed","recordId":row_id,"marker":marker,"bootBefore":state["bootBefore"],
                      "filesystemUuid":state["uuid"],"result":"passed"}))
elif action=="recreate":
    state=json.loads(state_path.read_text())
    assert api_has(state)
    subprocess.run(["docker","stop","staging-web","staging-api","staging-db"],check=True,stdout=subprocess.DEVNULL)
    subprocess.run(["docker","rm","staging-db"],check=True,stdout=subprocess.DEVNULL)
    subprocess.run([
        "docker","run","-d","--name","staging-db","--network","grocery-staging","--network-alias","db",
        "--restart","unless-stopped","--log-driver","none",
        "--health-cmd=pg_isready -U grocery_staging -d grocery_staging",
        "--health-interval=10s","--health-timeout=5s","--health-retries=6",
        "--mount","type=bind,src=/srv/grocery-staging/postgres,dst=/var/lib/postgresql/data",
        "--mount","type=bind,src=/run/grocery-staging/db-password,dst=/run/secrets/db-password,readonly",
        "-e","POSTGRES_PASSWORD_FILE=/run/secrets/db-password","-e","POSTGRES_USER=grocery_staging",
        "-e","POSTGRES_DB=grocery_staging",config["postgres"]],
        check=True,stdout=subprocess.DEVNULL)
    for attempt in range(60):
        r=subprocess.run(["docker","exec","staging-db","pg_isready","-U","grocery_staging","-d","grocery_staging"],
                         stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        if r.returncode==0: break
        time.sleep(2)
    else: raise SystemExit("Recreated database readiness failed")
    subprocess.run(["docker","start","staging-api","staging-web"],check=True,stdout=subprocess.DEVNULL)
    verify()
    assert inspect("staging-db",".Id") != state["oldDbContainerId"]
    assert api_has(state), "Record did not survive container recreation"
    state["containerRecreation"]="passed"
    state["newDbContainerId"]=inspect("staging-db",".Id")
    state_path.write_text(json.dumps(state,indent=2))
    print(json.dumps({"phase":"containerRecreation","recordId":state["id"],"result":"passed",
                      "oldDbContainerId":state["oldDbContainerId"],"newDbContainerId":state["newDbContainerId"]}))
elif action=="after-reboot":
    state=json.loads(state_path.read_text())
    assert state.get("containerRecreation")=="passed"
    assert boot_id()!=state["bootBefore"], "A new boot has not been observed"
    verify()
    assert api_has(state), "Record did not survive reboot"
    state["reboot"]="passed"
    state["bootAfter"]=boot_id()
    state_path.write_text(json.dumps(state,indent=2))
    print(json.dumps({"phase":"reboot","recordId":state["id"],"result":"passed",
                      "bootBefore":state["bootBefore"],"bootAfter":state["bootAfter"],
                      "filesystemUuid":state["uuid"]}))
elif action=="cleanup":
    state=json.loads(state_path.read_text())
    assert state.get("containerRecreation")=="passed" and state.get("reboot")=="passed"
    deleted=sql('DELETE FROM "GroceryList" WHERE id='+str(state["id"])+" AND item='"+state["marker"]+"' RETURNING id;")
    assert deleted==str(state["id"]), "Expected exactly the validation record to be removed"
    assert not api_has(state), "Validation record remains visible"
    report={"phase":"cleanup","result":"passed","recordId":state["id"],
            "containerRecreation":state["containerRecreation"],"reboot":state["reboot"],
            "bootBefore":state["bootBefore"],"bootAfter":state["bootAfter"],
            "filesystemUuid":state["uuid"],"release":config["release"]}
    pathlib.Path("/srv/grocery-staging/releases/persistence-verification.json").write_text(json.dumps(report,indent=2))
    state_path.unlink()
    verify()
    print(json.dumps(report))
else:
    raise SystemExit("Unknown verification phase")
