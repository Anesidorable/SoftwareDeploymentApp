"""Fetch only on the instance; never return decrypted values through SSM output."""
import json
import os
import pathlib
import subprocess
import sys

os.umask(0o077)
config = json.loads(pathlib.Path(sys.argv[1]).read_text())
response = subprocess.run(
    ["aws", "ssm", "get-parameter", "--name", config["secretParameter"],
     "--with-decryption", "--region", config["region"], "--output", "json"],
    check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
parameter = json.loads(response.stdout)["Parameter"]
password = parameter["Value"]
if parameter["Type"] != "SecureString" or len(password) < 24:
    raise SystemExit("Staging requires a SecureString password of at least 24 characters")
if any(c in password for c in "\r\n\0"):
    raise SystemExit("Password cannot contain line breaks or NUL")
runtime = pathlib.Path("/run/grocery-staging")
runtime.mkdir(mode=0o700, exist_ok=True)
(runtime / "db-password").write_text(password)
# Raw DB_PASSWORD preserves the application's encodeURIComponent(password) behavior.
# Do not interpolate an unencoded password into DATABASE_URL.
(runtime / "api.env").write_text(
    "HOST=0.0.0.0\nPORT=5000\nTRUST_PROXY=1\nAPP_ENV=staging\n"
    "DB_HOST=db\nDB_PORT=5432\nDB_USER=grocery_staging\nDB_NAME=grocery_staging\n"
    "DB_PASSWORD=" + password + "\nGIT_SHA=" + config["release"] + "\n")
