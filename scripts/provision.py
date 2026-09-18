#!/usr/bin/env python3
"""Self-service provisioning for the exported workshop (Python standard library).

Only an HTTP 404 means a resource is absent. Existing resources must carry our
ownership marker. Secrets stay in memory/Secret Manager; subprocess diagnostics
and HTTP bodies are deliberately not echoed because they can contain credentials.
"""
import argparse
import base64
import csv
import hashlib
from http.client import HTTPException
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
OWNER = "data-cloud-creator"
LABELS = {"managed-by": OWNER, "datacloud": "workshop"}
DESCRIPTION = "Managed by data-cloud-creator self-service provisioning v1"
REGION = "us-central1"
LOCATION = "US"
DATASET = "mcp_retail"
CLUSTER = "mcp-retail-cluster"
INSTANCE = "mcp-retail-primary"
NETWORK = "workshop-network"
RANGE = "workshop-psa-range"
CONNECTION = "alloydb_retail_conn"
AI_CONNECTION = "workshop_ai_connection"
PASSWORD_SECRET = "data-cloud-creator-alloydb-password"
ALLOY_TABLES = ("stores", "products", "inventory", "stock_movements")
BQ_TABLES = ("demographics_and_traffic", "historical_sales", "market_demand", "candidate_sites", "feedback_seed")
APIS = (
    "aiplatform", "alloydb", "artifactregistry", "bigquery", "bigqueryconnection",
    "cloudbuild", "compute", "dataplex", "run", "servicenetworking", "storage",
    "secretmanager", "apikeys", "developerknowledge", "mapstools",
)


class ProvisionError(Exception):
    pass


class CloudError(ProvisionError):
    def __init__(self, status, operation, reason=None, service=None):
        self.status = status
        self.reason = reason
        hint = "Check API enablement, project IAM and organization policies; a 403 does not necessarily mean an IAM denial." if status == 403 else "Check API availability, quota and resource status, then retry."
        if reason == "SERVICE_DISABLED":
            name = service if isinstance(service, str) and re.fullmatch(r"[a-z][a-z0-9-]*\.googleapis\.com", service) else "the required API"
            hint = f"SERVICE_DISABLED: enable {name} in the selected project, then retry. This is not an Owner-role failure."
        super().__init__(f"{operation} failed (HTTP {status}). {hint}")


def terminal_style(text, color, stream):
    # Match the shell launchers: color is optional, labels remain readable in
    # logs, and each output stream is checked independently.
    if not os.environ.get("NO_COLOR") and os.environ.get("TERM") != "dumb" and stream.isatty():
        return f"\033[{color}m{text}\033[0m"
    return text


def info(message, *, kind="info", stream=None):
    stream = sys.stdout if stream is None else stream
    color, label = {
        "info": ("1;36", "==>"),
        "success": ("32", " ok"),
        "warning": ("33", " !!"),
        "error": ("1;31", " xx"),
        "detail": ("2", "  ·"),
    }[kind]
    print(f"{terminal_style(label, color, stream)}  {message}", file=stream, flush=True)


def run(args, *, input_text=None):
    environment = dict(os.environ, CLOUDSDK_CORE_LOG_HTTP="false",
                       CLOUDSDK_CORE_DISABLE_FILE_LOGGING="true", CLOUDSDK_CORE_VERBOSITY="warning")
    result = subprocess.run(args, input=input_text, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=environment)
    if result.returncode:
        # Never include argv, stdout or stderr: some operations handle secrets.
        raise ProvisionError(f"{Path(args[0]).name} failed (exit {result.returncode}). Check authentication, project permissions and quotas. No command output was logged.")
    return result.stdout.strip()


def config_values(path):
    return dict(line.split("=", 1) for line in path.read_text().splitlines()
                if line and not line.startswith("#") and "=" in line)


def sql_literal(value):
    return "'" + value.replace("'", "''") + "'"


class Cloud:
    def __init__(self, project):
        self.project = project
        self.token = None
        self.token_time = 0
        self.uncertain_mutation = False

    def gcloud(self, *args):
        try:
            return run(["gcloud", *args, f"--project={self.project}", "--quiet"])
        except KeyboardInterrupt:
            if any(arg in ("create", "enable", "add-iam-policy-binding") for arg in args):
                self.uncertain_mutation = True
            raise

    def request(self, method, url, body=None, *, absent_ok=False, raw=False, quota_project=True):
        if not self.token or time.monotonic() - self.token_time > 2400:
            self.token = self.gcloud("auth", "print-access-token")
            if not self.token:
                raise ProvisionError("No gcloud access token. Run gcloud auth login.")
            self.token_time = time.monotonic()
        data = body if isinstance(body, bytes) else (json.dumps(body).encode() if body is not None else None)
        headers = {
            "Authorization": "Bearer " + self.token,
            "Content-Type": "application/json", "Accept": "application/json",
        }
        if quota_project:
            headers["x-goog-user-project"] = self.project
        request = Request(url, data=data, method=method, headers=headers)
        try:
            with urlopen(request, timeout=180) as response:
                value = response.read()
        except HTTPError as exc:
            if absent_ok and exc.code == 404:
                return None
            if method != "GET" and exc.code >= 500:
                self.uncertain_mutation = True
            # Never echo error messages or arbitrary metadata: upstream errors
            # may contain credentials. Only recognize a fixed diagnostic code.
            reason, service = None, None
            try:
                error = json.loads(exc.read(65536))
                for detail in error.get("error", {}).get("details", []):
                    if detail.get("@type") == "type.googleapis.com/google.rpc.ErrorInfo" and detail.get("reason") == "SERVICE_DISABLED":
                        reason, service = "SERVICE_DISABLED", detail.get("metadata", {}).get("service")
            except (ValueError, AttributeError, TypeError, OSError, HTTPException):
                pass
            raise CloudError(exc.code, method + " " + url.split("?")[0], reason, service) from None
        except (URLError, TimeoutError, OSError, HTTPException):
            if method != "GET":
                self.uncertain_mutation = True
            raise ProvisionError("Google Cloud request interrupted. Its outcome may be unknown; retry this command to reconcile it. No automatic mutation retry was attempted.") from None
        except KeyboardInterrupt:
            if method != "GET":
                self.uncertain_mutation = True
            raise
        if raw:
            return value
        try:
            return json.loads(value) if value else {}
        except (ValueError, UnicodeError):
            raise ProvisionError("Google Cloud returned an unexpected response; no response body was logged.") from None

    def get(self, url):
        return self.request("GET", url, absent_ok=True)

    def wait(self, operation, base):
        deadline = time.monotonic() + 2400
        while not operation.get("done"):
            if time.monotonic() > deadline:
                self.uncertain_mutation = True
                raise ProvisionError("Cloud operation is still running after 40 minutes. Retry later; resources are preserved.")
            info("Waiting for Google Cloud operation...", kind="detail")
            time.sleep(15)
            operation = self.request("GET", base + "/" + operation["name"])
        if operation.get("error"):
            raise ProvisionError("Cloud operation failed. Inspect the operation in Google Cloud Console for quota or policy details, then retry.")
        return operation.get("response", {})

    def query(self, statement, *, expect_rows=True):
        result = run(["bq", f"--project_id={self.project}", f"--location={LOCATION}", "query",
                      "--use_legacy_sql=false", "--format=json", "--quiet", "--label=datacloud:workshop"], input_text=statement)
        # ASSERT and DDL can return human-readable success messages even with
        # --format=json. For these statements the exit status is the result.
        if not expect_rows:
            return []
        try:
            rows = json.loads(result or "[]")
        except ValueError:
            raise ProvisionError("BigQuery returned non-JSON output for a query expected to return rows. No response content was logged.") from None
        if not isinstance(rows, list):
            raise ProvisionError("BigQuery returned an unexpected row format. No response content was logged.")
        return rows

    def grant(self, member, role):
        for attempt in range(6):
            try:
                self.gcloud("projects", "add-iam-policy-binding", self.project,
                            "--member=" + member, "--role=" + role, "--condition=None", "--format=none")
                return
            except ProvisionError:
                if attempt == 5:
                    raise
                info("Waiting for service-account IAM propagation...", kind="detail")
                time.sleep(10)


class Provisioner:
    def __init__(self, cloud, bundle):
        self.cloud = cloud
        self.project = cloud.project
        self.bundle = Path(bundle)
        self.manifest = json.loads((self.bundle / "manifest.json").read_text())
        self.seed = hashlib.sha256((self.bundle / "manifest.json").read_bytes()).hexdigest()
        self.schema = hashlib.sha256((self.bundle / "sql/alloydb-schema.sql").read_bytes()).hexdigest()
        self.bucket = self.project + "-workshop-data"
        self.storage = "https://storage.googleapis.com/storage/v1/b/" + self.bucket
        self.alloy = f"https://alloydb.googleapis.com/v1/projects/{self.project}/locations/{REGION}/clusters/{CLUSTER}"
        self.compute = f"https://compute.googleapis.com/compute/v1/projects/{self.project}/global"
        self.bq = f"https://bigquery.googleapis.com/bigquery/v2/projects/{self.project}"
        self.connections = f"https://bigqueryconnection.googleapis.com/v1/projects/{self.project}/locations/us/connections"
        self.secrets = f"https://secretmanager.googleapis.com/v1/projects/{self.project}/secrets"
        self.sql_dir = self.bundle / "sql"
        self.number = ""
        self.account = ""
        self.generation = ""
        self.reset = False
        self.lock_generation = None

    def validate_bundle(self):
        if set(self.manifest["tables"]) != set(ALLOY_TABLES + BQ_TABLES):
            raise ProvisionError("Seed bundle has an unexpected table set. Re-export it from the source repository.")
        for table, entry in self.manifest["tables"].items():
            path = self.bundle / (table + ".csv")
            if hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
                raise ProvisionError(f"Seed checksum mismatch: {table}.csv")
            if any(not re.fullmatch(r"[a-z][a-z0-9_]*", col) for col in entry["columns"]):
                raise ProvisionError("Invalid seed column name.")
        for name in ("alloydb-schema.sql", "alloydb-comments.sql", "customer-feedback.sql"):
            if not (self.sql_dir / name).is_file():
                raise ProvisionError("Incomplete seed bundle: missing " + name)

    def preflight(self):
        self.validate_bundle()
        config = config_values(ROOT / "config/workshop.env")
        if config.get("DAK_GCP_REGION") != REGION or config.get("CLOUD_RUN_REGION") != REGION:
            raise ProvisionError("Self-service scenario provisioning currently requires us-central1 in config/workshop.env.")
        for command in ("gcloud", "bq"):
            if not shutil.which(command):
                raise ProvisionError(f"Missing {command}. Install the Google Cloud CLI (including bq).")
        accounts = json.loads(self.cloud.gcloud("auth", "list", "--filter=status:ACTIVE", "--format=json"))
        if len(accounts) != 1:
            raise ProvisionError("No single active gcloud account. Run gcloud auth login.")
        self.account = accounts[0]["account"]
        if self.account.endswith("gserviceaccount.com"):
            raise ProvisionError("Run this self-service command as your personal Google account, which must own the project.")
        project = json.loads(self.cloud.gcloud("projects", "describe", self.project, "--format=json"))
        self.number = str(project["projectNumber"])
        billing = json.loads(self.cloud.gcloud("billing", "projects", "describe", self.project, "--format=json"))
        if not billing.get("billingEnabled"):
            raise ProvisionError("Billing is not enabled on this project. Attach a billing account, then retry.")
        permissions = ["serviceusage.services.enable", "resourcemanager.projects.setIamPolicy", "resourcemanager.projects.getIamPolicy"]
        # Bootstrap metadata check: the new project may not yet have Resource
        # Manager enabled. An explicit user-project quota header would require
        # that API before we can even verify permission to enable APIs. Use the
        # authenticated client's quota here, as gcloud's project reads do.
        # The target project remains explicit in the URL; workload requests
        # continue to use the selected project's quota after API enablement.
        result = self.cloud.request("POST", f"https://cloudresourcemanager.googleapis.com/v1/projects/{self.project}:testIamPermissions", {"permissions": permissions}, quota_project=False)
        if not set(permissions).issubset(result.get("permissions", [])):
            raise ProvisionError("Your account lacks project administration permissions. Run as Project Owner; another login will not fix IAM access.")
        info(f"Project: {self.project}; account: {self.account}; billing enabled.", kind="success")

    @staticmethod
    def owned(resource, name, *, description=False):
        if resource is not None:
            matches = resource.get("description") == DESCRIPTION if description else resource.get("labels", {}).get("managed-by") == OWNER
            if not matches:
                raise ProvisionError(f"Resource-name conflict: {name} already exists and is not managed by this command. Use a fresh project. --reset-data never adopts existing resources.")
        return resource

    def inspect(self):
        # API enablement happens before these reads so DISABLED_API is never
        # mistaken for a missing resource. No resources are adopted on 403.
        cfg = config_values(ROOT / "config/workshop.env")
        checks = [(self.storage, self.bucket, False), (self.alloy, CLUSTER, False),
                  (self.alloy + "/instances/" + INSTANCE, INSTANCE, False),
                  (self.bq + "/datasets/" + DATASET, DATASET, False),
                  (self.compute + "/networks/" + NETWORK, NETWORK, True),
                  (self.compute + "/addresses/" + RANGE, RANGE, True),
                  (self.connections + "/" + CONNECTION, CONNECTION, True),
                  (self.connections + "/" + AI_CONNECTION, AI_CONNECTION, True)]
        for name in (PASSWORD_SECRET, cfg["DK_SECRET_ID"], cfg["MAPS_SECRET_ID"]):
            checks.append((self.secrets + "/" + name, name, False))
        for url, name, description in checks:
            resource = self.owned(self.cloud.get(url), name, description=description)
            if resource and name == DATASET and resource.get("location", "").upper() != LOCATION:
                raise ProvisionError("Workshop dataset is in a different location; refusing to change it.")
            if resource and name == self.bucket and str(resource.get("projectNumber")) != self.number:
                raise ProvisionError("The staging bucket belongs to a different project.")
            if resource and name == self.bucket and resource.get("location", "").lower() != REGION:
                raise ProvisionError("The staging bucket is in a different location. Use a fresh project.")
            if resource and name == CLUSTER:
                network = resource.get("networkConfig", {}).get("network", resource.get("network", ""))
                if not network.endswith("/networks/" + NETWORK):
                    raise ProvisionError("Workshop AlloyDB cluster uses a different network; refusing to change it.")
            if resource and name == CONNECTION:
                asset = resource.get("configuration", {}).get("asset", {})
                expected = {f"//alloydb.googleapis.com/projects/{project}/locations/{REGION}/clusters/{CLUSTER}/instances/{INSTANCE}" for project in (self.project, self.number)}
                if asset.get("googleCloudResource") not in expected or asset.get("database") != "postgres":
                    raise ProvisionError("Workshop federation connection points at a different database. Refusing to change it.")

    def object_url(self, name):
        return self.storage + "/o/" + quote(name, safe="")

    def put_object(self, name, data, generation=None):
        params = {"uploadType": "media", "name": name}
        if generation is not None:
            params["ifGenerationMatch"] = str(generation)
        url = "https://storage.googleapis.com/upload/storage/v1/b/" + self.bucket + "/o?" + urlencode(params)
        return self.cloud.request("POST", url, data)

    def acquire(self):
        if self.cloud.get(self.storage) is None:
            self.cloud.request("POST", "https://storage.googleapis.com/storage/v1/b?" + urlencode({"project": self.project}), {
                "name": self.bucket, "location": REGION, "labels": LABELS,
                "iamConfiguration": {"uniformBucketLevelAccess": {"enabled": True}, "publicAccessPrevention": "enforced"},
            })
        try:
            lock = self.put_object("provision/lock", b"Self-service provisioning in progress.\n", 0)
        except CloudError as exc:
            if exc.status != 412:
                raise
            raise ProvisionError(f"Another run holds gs://{self.bucket}/provision/lock. If it was forcibly terminated, first confirm no run is active, then remove ONLY that lock object in Cloud Storage and retry.") from None
        self.lock_generation = lock["generation"]

    def release(self):
        if self.lock_generation is not None:
            self.cloud.request("DELETE", self.object_url("provision/lock") + "?ifGenerationMatch=" + self.lock_generation)
            self.lock_generation = None

    def prepare_state(self, reset):
        url = self.object_url("provision/state.json")
        metadata = self.cloud.get(url)
        state = self.cloud.request("GET", url + "?alt=media") if metadata else None
        if state and (state.get("version") != 1 or state.get("project_number") != self.number):
            raise ProvisionError("Provisioning state does not match this project/version.")
        if state and (not re.fullmatch(r"[a-f0-9]{24}", state.get("generation", "")) or type(state.get("reset")) is not bool):
            raise ProvisionError("Invalid provisioning checkpoint. Restore its original state before retrying.")
        if state and state.get("schema") != self.schema:
            raise ProvisionError("AlloyDB schema has changed since this project was provisioned. Use the original checkout or a fresh project; --reset-data does not migrate schemas.")
        if state and state.get("seed") != self.seed and not reset:
            raise ProvisionError("This project was seeded from a different bundle. Use the original checkout to resume, or --reset-data to replace only the demo tables.")
        if state is None or reset:
            state = {"version": 1, "project_number": self.number, "seed": self.seed,
                     "schema": self.schema, "generation": secrets.token_hex(12), "reset": bool(reset)}
            self.put_object("provision/state.json", json.dumps(state).encode(), metadata["generation"] if metadata else 0)
        self.generation, self.reset = state["generation"], state["reset"]

    def network(self):
        info("Preparing dedicated workshop networking...")
        if self.cloud.get(self.compute + "/networks/" + NETWORK) is None:
            self.cloud.gcloud("compute", "networks", "create", NETWORK, "--subnet-mode=custom", "--description=" + DESCRIPTION)
        if self.cloud.get(self.compute + "/addresses/" + RANGE) is None:
            self.cloud.gcloud("compute", "addresses", "create", RANGE, "--global", "--purpose=VPC_PEERING",
                              "--prefix-length=16", "--network=" + NETWORK, "--description=" + DESCRIPTION)
        network = f"projects/{self.number}/global/networks/{NETWORK}"
        url = "https://servicenetworking.googleapis.com/v1/services/servicenetworking.googleapis.com/connections"
        existing = self.cloud.request("GET", url + "?" + urlencode({"network": network})).get("connections", [])
        if existing:
            if not any(RANGE in item.get("reservedPeeringRanges", []) for item in existing):
                raise ProvisionError("Workshop network has an unexpected private service connection. Refusing to change it.")
        else:
            operation = self.cloud.request("POST", url, {"network": network, "reservedPeeringRanges": [RANGE]})
            self.cloud.wait(operation, "https://servicenetworking.googleapis.com/v1")

    def password(self):
        url = self.secrets + "/" + PASSWORD_SECRET
        secret = self.cloud.get(url)
        cluster = self.cloud.get(self.alloy)
        if secret is None:
            if cluster is not None:
                raise ProvisionError("AlloyDB exists but its password secret is missing. Restore the secret; provisioning will not rotate a live database password.")
            self.cloud.request("POST", self.secrets + "?secretId=" + PASSWORD_SECRET,
                               {"replication": {"automatic": {}}, "labels": LABELS})
        versions = self.cloud.request("GET", url + "/versions?filter=state%3DENABLED&pageSize=1").get("versions", [])
        if versions:
            value = self.cloud.request("GET", "https://secretmanager.googleapis.com/v1/" + versions[0]["name"] + ":access")
            return base64.b64decode(value["payload"]["data"]).decode()
        if cluster is not None:
            raise ProvisionError("AlloyDB password has no enabled secret version. Restore it before retrying.")
        password = "Wk9!" + secrets.token_urlsafe(30)
        self.cloud.request("POST", url + ":addVersion", {"payload": {"data": base64.b64encode(password.encode()).decode()}})
        return password

    def wait_ready(self, url):
        for _ in range(160):
            resource = self.cloud.request("GET", url)
            if resource.get("state") == "READY" and not resource.get("reconciling", False):
                return resource
            if resource.get("state") in ("FAILED", "DELETING", "STOPPED"):
                raise ProvisionError("AlloyDB is not usable. Inspect its status in Google Cloud Console before retrying.")
            info("Waiting for AlloyDB to be ready...", kind="detail")
            time.sleep(15)
        raise ProvisionError("AlloyDB is still starting after 40 minutes; retry later.")

    def alloydb(self, password):
        info("Preparing AlloyDB (a new cluster/instance can take 10–15 minutes)...")
        if self.cloud.get(self.alloy) is None:
            parent = self.alloy.rsplit("/", 1)[0]
            operation = self.cloud.request("POST", parent + "?clusterId=" + CLUSTER, {
                "labels": LABELS, "databaseVersion": "POSTGRES_17",
                "networkConfig": {"network": f"projects/{self.number}/global/networks/{NETWORK}", "allocatedIpRange": RANGE},
                "initialUser": {"user": "postgres", "password": password},
            })
            self.cloud.wait(operation, "https://alloydb.googleapis.com/v1")
        self.wait_ready(self.alloy)
        url = self.alloy + "/instances/" + INSTANCE
        if self.cloud.get(url) is None:
            operation = self.cloud.request("POST", self.alloy + "/instances?instanceId=" + INSTANCE, {
                "labels": LABELS, "instanceType": "PRIMARY", "machineConfig": {"cpuCount": 2},
                "databaseFlags": {"alloydb.iam_authentication": "on", "password.enforce_complexity": "on"},
            })
            self.cloud.wait(operation, "https://alloydb.googleapis.com/v1")
        instance = self.wait_ready(url)
        if instance.get("databaseFlags", {}).get("alloydb.iam_authentication") != "on":
            raise ProvisionError("AlloyDB IAM authentication was changed. Restore that flag before retrying.")
        users = self.cloud.request("GET", self.alloy + "/users").get("users", [])
        if not any(user["name"].rsplit("/", 1)[-1] == self.account for user in users):
            self.cloud.gcloud("alloydb", "users", "create", self.account, "--cluster=" + CLUSTER,
                              "--region=" + REGION, "--type=IAM_BASED", "--superuser=true")
        self.retry_read(lambda: self.sql("SELECT 1", read_only=True))

    def sql(self, statement, read_only=False):
        result = self.cloud.request("POST", "https://alloydb.googleapis.com/mcp", {
            "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
                "name": "execute_sql_read_only" if read_only else "execute_sql",
                "arguments": {"instance": f"projects/{self.project}/locations/{REGION}/clusters/{CLUSTER}/instances/{INSTANCE}",
                              "database": "postgres", "sqlStatement": statement},
            },
        })
        tool = result.get("result", {})
        structured = tool.get("structuredContent", {})
        if "error" in result or tool.get("isError") or structured.get("metadata", {}).get("status") != "OK":
            raise ProvisionError("AlloyDB SQL failed or returned an unexpected result. Check IAM/database access and retry; transaction checkpoints preserve completed inserts.")
        return [[v.get("value") for v in row.get("values", [])]
                for block in structured.get("sqlResults", []) for row in block.get("rows", [])]

    @staticmethod
    def retry_read(action):
        for attempt in range(12):
            try:
                return action()
            except ProvisionError:
                if attempt == 11:
                    raise
                info("Waiting for service/IAM readiness...", kind="detail")
                time.sleep(15)

    def seed_alloydb(self):
        info("Loading AlloyDB demo tables with transactional checkpoints...")
        initialized = self.sql("SELECT to_regclass('workshop_setup.batches') IS NOT NULL", read_only=True)
        has_checkpoint = str(initialized[0][0]).lower() in ("true", "t", "1")
        if not has_checkpoint:
            names = ",".join(sql_literal(name) for name in ALLOY_TABLES)
            rows = self.sql(f"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ({names})", read_only=True)
            if int(rows[0][0]):
                raise ProvisionError("AlloyDB demo table names already exist without provisioning checkpoints. Refusing to replace them, even with --reset-data.")
            schema = (self.sql_dir / "alloydb-schema.sql").read_text()
            schema = "\n".join(line for line in schema.splitlines() if not line.startswith("DROP TABLE"))
            self.sql("BEGIN; SET LOCAL search_path=public; " + schema + "\nCREATE SCHEMA workshop_setup; "
                     "CREATE TABLE workshop_setup.batches (generation TEXT NOT NULL, batch TEXT NOT NULL, PRIMARY KEY(generation,batch)); COMMIT;")
        generation = sql_literal(self.generation)
        init = "TRUNCATE TABLE " + ",".join("public." + name for name in ALLOY_TABLES) + ";" if self.reset else ""
        self.sql(f"DO $workshop$ BEGIN IF NOT EXISTS (SELECT 1 FROM workshop_setup.batches WHERE generation={generation} AND batch='init') THEN {init} INSERT INTO workshop_setup.batches VALUES ({generation},'init'); END IF; END; $workshop$;")
        done = {row[0] for row in self.sql(f"SELECT batch FROM workshop_setup.batches WHERE generation={generation}", read_only=True)}
        for table in ALLOY_TABLES:
            with (self.bundle / (table + ".csv")).open(newline="") as handle:
                rows = list(csv.reader(handle))
            columns = ",".join(self.manifest["tables"][table]["columns"])
            for start in range(0, len(rows), 250):
                batch = f"{table}-{start}"
                if batch in done:
                    continue
                values = ",".join("(" + ",".join(sql_literal(value) for value in row) + ")" for row in rows[start:start + 250])
                self.sql(f"DO $workshop$ BEGIN IF NOT EXISTS (SELECT 1 FROM workshop_setup.batches WHERE generation={generation} AND batch={sql_literal(batch)}) THEN INSERT INTO public.{table} ({columns}) VALUES {values}; INSERT INTO workshop_setup.batches VALUES ({generation},{sql_literal(batch)}); END IF; END; $workshop$;")
            info("Ready: " + table, kind="success")
        self.sql("BEGIN; SET LOCAL search_path=public;\n" + (self.sql_dir / "alloydb-comments.sql").read_text() + "\nCOMMIT;")

    def connection(self, name, body):
        url = self.connections + "/" + name
        existing = self.cloud.get(url)
        if existing is None:
            self.cloud.request("POST", self.connections + "?connectionId=" + name, dict(body, description=DESCRIPTION))
        return self.cloud.request("GET", url)

    def runtime(self, password):
        info("Preparing BigQuery connections and service-account permissions...")
        ai = self.connection(AI_CONNECTION, {"cloudResource": {}})
        sa = ai.get("cloudResource", {}).get("serviceAccountId")
        if not sa:
            raise ProvisionError("Workshop AI connection is not a Cloud Resource connection.")
        self.cloud.grant("serviceAccount:" + sa, "roles/aiplatform.user")
        defaults = self.cloud.query("SELECT option_value FROM `region-us`.INFORMATION_SCHEMA.EFFECTIVE_PROJECT_OPTIONS WHERE option_name='default_cloud_resource_connection_id'")
        default = defaults[0].get("option_value") if defaults else None
        if not default:
            self.cloud.query(f"ALTER PROJECT `{self.project}` SET OPTIONS (`region-us.default_cloud_resource_connection_id` = '{AI_CONNECTION}')", expect_rows=False)
        elif default.strip('"') != AI_CONNECTION:
            info("  Preserving the existing BigQuery default connection; the named workshop_ai_connection is available for workshop models.")
        self.connection(CONNECTION, {"configuration": {
            "connectorId": "google-alloydb",
            "asset": {"googleCloudResource": f"//alloydb.googleapis.com/projects/{self.project}/locations/{REGION}/clusters/{CLUSTER}/instances/{INSTANCE}", "database": "postgres"},
            "authentication": {"usernamePassword": {"username": "postgres", "password": {"plaintext": password}}},
        }})
        self.cloud.grant(f"serviceAccount:service-{self.number}@gcp-sa-bigqueryconnection.iam.gserviceaccount.com", "roles/alloydb.client")
        self.cloud.grant(f"serviceAccount:{self.number}-compute@developer.gserviceaccount.com", "roles/run.builder")

    def job(self, key, configuration):
        # A failed load/CTAS job is atomic and cannot be resubmitted under the
        # same ID. Skip only terminal failures; uncertain/running jobs are
        # always awaited, and successful jobs are never submitted twice.
        for attempt in range(100):
            job_id = "workshop_" + self.generation + "_" + key + "_" + str(attempt)
            url = self.bq + "/jobs/" + job_id + "?location=" + LOCATION
            job = self.cloud.get(url)
            if not job or not (job.get("status", {}).get("state") == "DONE" and job["status"].get("errorResult")):
                break
        else:
            raise ProvisionError("Too many failed attempts for this BigQuery job. Inspect Job history before retrying.")
        if job is None:
            job = self.cloud.request("POST", self.bq + "/jobs", {
                "jobReference": {"projectId": self.project, "location": LOCATION, "jobId": job_id},
                "configuration": dict(configuration, labels={"datacloud": "workshop"}),
            })
        for _ in range(240):
            if job.get("status", {}).get("state") == "DONE":
                if job["status"].get("errorResult"):
                    raise ProvisionError(f"BigQuery job {job_id} failed. Inspect it in BigQuery Job history, fix the cause, then retry without --reset-data.")
                return
            time.sleep(5)
            job = self.cloud.request("GET", url)
        self.cloud.uncertain_mutation = True
        raise ProvisionError("BigQuery job is still running. Wait for it to finish before releasing the lock; retries reuse the same job.")

    def seed_bigquery(self):
        info("Loading BigQuery demo tables...")
        descriptions = json.loads((ROOT / "config/table-descriptions.json").read_text())
        dataset_url = self.bq + "/datasets/" + DATASET
        if self.cloud.get(dataset_url) is None:
            self.cloud.request("POST", self.bq + "/datasets", {"datasetReference": {"projectId": self.project, "datasetId": DATASET},
                               "location": LOCATION, "labels": LABELS, "description": "Charlie's Coffee synthetic workshop scenario"})
        for table in BQ_TABLES:
            path = self.bundle / (table + ".csv")
            object_name = "data/" + self.seed + "/" + table + ".csv"
            if self.cloud.get(self.object_url(object_name)) is None:
                self.put_object(object_name, path.read_bytes(), 0)
            schema = json.loads((self.bundle / "schemas" / (table + ".json")).read_text())
            table_url = dataset_url + "/tables/" + table
            metadata = self.cloud.get(table_url)
            if metadata and metadata.get("labels", {}).get("workshop_generation") == self.generation:
                info("Preserved: " + table, kind="success")
                continue
            self.job("load_" + table, {"load": {
                "sourceUris": ["gs://" + self.bucket + "/" + object_name], "sourceFormat": "CSV", "schema": {"fields": schema},
                "destinationTable": {"projectId": self.project, "datasetId": DATASET, "tableId": table},
                "writeDisposition": "WRITE_TRUNCATE" if self.reset else "WRITE_EMPTY",
            }})
            self.cloud.request("PATCH", table_url, {"labels": dict(LABELS, workshop_generation=self.generation), "description": descriptions[table]})
        table_url = dataset_url + "/tables/customer_feedback"
        existing = self.cloud.get(table_url)
        if not existing or existing.get("labels", {}).get("workshop_generation") != self.generation:
            sql = (self.sql_dir / "customer-feedback.sql").read_text().replace("@WORKSHOP_DATASET@", self.project + "." + DATASET)
            # Initial creation cannot overwrite a table created independently.
            if not self.reset:
                sql = sql.replace("CREATE OR REPLACE TABLE", "CREATE TABLE", 1)
            self.job("reviews", {"query": {"query": sql, "useLegacySql": False}})
            schema = json.loads((self.bundle / "schemas/customer_feedback.json").read_text())
            self.cloud.request("PATCH", table_url, {"labels": dict(LABELS, workshop_generation=self.generation), "schema": {"fields": schema}, "description": descriptions["customer_feedback"]})

    def verify(self):
        info("Verifying data, federation and BigQuery AI...")
        # Check that the scenario is usable without treating attendee edits as
        # grounds for silently resetting their data.
        info("Checking AlloyDB scenario integrity...", kind="detail")
        counts = self.sql("SELECT COUNT(*) FROM public.inventory i JOIN public.products p USING (sku) WHERE i.stock_count <= p.reorder_threshold", read_only=True)
        if not counts or int(counts[0][0]) < 3:
            raise ProvisionError("Scenario verification failed: fewer than three below-threshold inventory pairs. Data was preserved; --reset-data restores the demo.")
        info("Checking customer review completeness...", kind="detail")
        self.cloud.query(f"ASSERT (SELECT COUNTIF(review_text IS NULL OR LENGTH(TRIM(review_text)) < 20) = 0 AND COUNT(*) = 300 FROM `{self.project}.{DATASET}.customer_feedback`) AS 'Incomplete review corpus';", expect_rows=False)
        query = f"SELECT COUNT(*) FROM EXTERNAL_QUERY('projects/{self.project}/locations/us/connections/{CONNECTION}', 'SELECT movement_id FROM public.stock_movements')"
        info("Checking BigQuery to AlloyDB federation...", kind="detail")
        self.retry_read(lambda: self.cloud.query(query))
        info("Checking AI.GENERATE...", kind="detail")
        self.cloud.query("SELECT AI.GENERATE('Reply with OK').result")
        info("Checking AI.FORECAST...", kind="detail")
        self.cloud.query(f"SELECT * FROM AI.FORECAST((SELECT week_start_date AS ts, SUM(net_revenue) AS revenue FROM `{self.project}.{DATASET}.historical_sales` GROUP BY ts), data_col => 'revenue', timestamp_col => 'ts', horizon => 4)")

    def execute(self, reset=False, yes=False):
        self.preflight()
        info(f"This prepares billable AlloyDB, BigQuery, Storage, networking, MCP keys and secrets in {self.project}.")
        info("AlloyDB continues to incur charges until you remove it. Typical first run: 15–20 minutes.", kind="warning")
        if reset:
            info("RESET DATA: replaces ONLY public.{stores,products,inventory,stock_movements} in mcp-retail-cluster/postgres and mcp_retail.{" + ",".join(BQ_TABLES + ("customer_feedback",)) + "}. Credentials and other resources are preserved.", kind="warning")
        if not yes and input(terminal_style("Continue? [y/N] ", "1", sys.stdout)).strip().lower() not in ("y", "yes"):
            info("Aborted; nothing was created.", kind="warning")
            return
        info("Enabling required APIs...")
        self.cloud.gcloud("services", "enable", *(api + ".googleapis.com" for api in APIS))
        self.inspect()
        self.acquire()
        try:
            self.prepare_state(reset)
            self.network()
            password = self.password()
            self.alloydb(password)
            self.runtime(password)
            del password
            self.seed_alloydb()
            self.seed_bigquery()
            info("Preparing the two restricted MCP API keys and secrets...")
            run(["/bin/bash", str(ROOT / "bin/lib/provision-keys.sh"), self.project])
            self.verify()
        except KeyboardInterrupt:
            # The SDK or a submitted BigQuery job may still run after Ctrl-C.
            self.cloud.uncertain_mutation = True
            raise
        finally:
            already_failing = sys.exc_info()[0] is not None
            if getattr(self.cloud, "uncertain_mutation", False):
                info(f"A request has an uncertain outcome; retained gs://{self.bucket}/provision/lock. Confirm pending operations/jobs have finished before removing only the lock and retrying.", kind="warning")
                if not already_failing:
                    raise ProvisionError("A cloud request needs reconciliation before setup can be declared complete.")
            else:
                try:
                    self.release()
                except ProvisionError:
                    info(f"Could not release gs://{self.bucket}/provision/lock. After confirming this run has ended, remove only that lock object before retrying.", kind="warning")
                    if not already_failing:
                        raise
        info(f"Project ready: {self.project}", kind="success")
        info(f"Next: ./bin/setup {self.project}\n          ./bin/doctor", kind="detail")


def prepare_bundle(output):
    """Build from organizer sources locally; the export ships only its outputs."""
    config = config_values(ROOT / "config/provisioning.env")
    anchor = config.get("SCENARIO_ANCHOR_DATE") or json.loads((ROOT / "generator/manifest.json").read_text())["anchor_date"]
    run([sys.executable, str(ROOT / "generator/generate.py"), "--out-dir", str(output), "--anchor-date", anchor])
    shutil.copytree(ROOT / "generator/schemas", output / "schemas")
    (output / "sql").mkdir()
    for name in ("alloydb-schema.sql", "alloydb-comments.sql", "customer-feedback.sql"):
        shutil.copyfile(ROOT / "sql" / name, output / "sql" / name)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Populate one existing, billing-enabled Google Cloud project as its Owner. No project creation or local agent configuration.")
    parser.add_argument("project_id")
    parser.add_argument("--yes", action="store_true", help="Accept the printed billable-resource plan (and data reset when requested).")
    parser.add_argument("--reset-data", action="store_true", help="Explicitly replace only this command's demo tables and regenerate reviews; never adopt conflicting resources.")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[a-z][a-z0-9-]{4,28}[a-z0-9]", args.project_id):
        parser.error("Invalid Google Cloud project ID.")
    try:
        bundle = ROOT / "data/seed"
        with tempfile.TemporaryDirectory(prefix="workshop-seed-") as temp:
            if not bundle.is_dir():
                if not (ROOT / "generator/generate.py").is_file():
                    raise ProvisionError("Seed bundle missing. Use a complete workshop checkout.")
                bundle = Path(temp) / "seed"
                prepare_bundle(bundle)
            Provisioner(Cloud(args.project_id), bundle).execute(args.reset_data, args.yes)
        return 0
    except Exception as exc:
        # Malformed cloud data must not produce a traceback with local values.
        message = str(exc) if isinstance(exc, ProvisionError) else "Unexpected local file or cloud response. Check that the checkout is complete and retry."
        info("ERROR: " + message, kind="error", stream=sys.stderr)
        return 1
    except (KeyboardInterrupt, EOFError):
        info("Interrupted. Completed resources/data are preserved; retry the same command without --reset-data to resume.", kind="warning", stream=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
