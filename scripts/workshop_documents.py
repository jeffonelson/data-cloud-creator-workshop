"""Shared, create-only lease bundle and Cloud Storage support (stdlib only).

The organizer CLI and self-service provisioner use the same implementation.
Existing objects are verified, never overwritten, even during a table reset.
"""
import argparse
import base64
import csv
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys
from urllib.parse import quote, urlencode


class DocumentError(Exception):
    pass


def validate_documents(bundle, manifest):
    bundle = Path(bundle)
    columns = manifest["tables"]["candidate_sites"]["columns"]
    with (bundle / "candidate_sites.csv").open(newline="") as handle:
        sites = {row["site_id"]: row for row in csv.DictReader(handle, fieldnames=columns)}
    documents = manifest.get("documents", [])
    if len(documents) != len(sites) or {d.get("site_id") for d in documents} != set(sites):
        raise DocumentError("Lease bundle must contain exactly one document per candidate site. Re-export the workshop.")
    for entry in documents:
        sid = entry["site_id"]
        if not re.fullmatch(r"SITE-\d{3}", sid) or entry.get("filename") != f"leases/{sid}-lease.pdf":
            raise DocumentError("Invalid lease filename in bundle manifest.")
        path = bundle / entry["filename"]
        if path.is_symlink() or not path.is_file():
            raise DocumentError(f"Missing lease document: {sid}.")
        data = path.read_bytes()
        if not data.startswith(b"%PDF-") or len(data) > 8 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != entry.get("sha256"):
            raise DocumentError(f"Lease checksum, format or size mismatch: {sid}. Re-export the workshop.")
        for field in ("monthly_rent", "available_sqft", "lease_term_months"):
            if str(entry.get("site", {}).get(field)) != sites[sid][field]:
                raise DocumentError(f"Lease facts differ from candidate_sites: {sid} / {field}. Regenerate the PDFs before exporting.")
    return documents


def bundle_documents(source, output, manifest):
    """Copy only explicitly indexed PDFs; never include authoring notes/source."""
    source, output = Path(source), Path(output)
    documents = json.loads((source / "manifest.json").read_text())
    for entry in documents:
        sid = entry["site_id"]
        if not re.fullmatch(r"SITE-\d{3}", sid) or entry.get("filename") != f"leases/{sid}-lease.pdf":
            raise DocumentError("Invalid source lease filename.")
        path = source / Path(entry["filename"]).name
        if path.is_symlink():
            raise DocumentError("Lease sources must be ordinary files.")
        (output / "leases").mkdir(exist_ok=True)
        shutil.copyfile(path, output / entry["filename"])
    manifest["documents"] = documents
    validate_documents(output, manifest)


class DocumentStore:
    def __init__(self, cloud, bundle, region="us-central1"):
        self.cloud = cloud
        self.bundle = Path(bundle)
        self.region = region
        self.bucket = cloud.project + "-charlies-documents"
        self.url = "https://storage.googleapis.com/storage/v1/b/" + self.bucket
        self.manifest = json.loads((self.bundle / "manifest.json").read_text())
        self.documents = validate_documents(self.bundle, self.manifest)

    def inspect(self, project_number):
        value = self.cloud.get(self.url)
        if value is not None:
            if value.get("labels", {}).get("managed-by") != "data-cloud-creator":
                raise DocumentError("Documents bucket name is already in use by an unmanaged resource. No resources were adopted.")
            if str(value.get("projectNumber")) != str(project_number) or value.get("location", "").lower() != self.region.lower():
                raise DocumentError("Documents bucket belongs to another project or region. No resources were changed.")
            iam = value.get("iamConfiguration", {})
            if not iam.get("uniformBucketLevelAccess", {}).get("enabled") or iam.get("publicAccessPrevention") != "enforced":
                raise DocumentError("Documents bucket must have uniform bucket-level access and public access prevention enforced. Review its configuration before retrying.")
        return value

    def object_url(self, name):
        return self.url + "/o/" + quote(name, safe="")

    def check_object(self, entry, metadata):
        data = (self.bundle / entry["filename"]).read_bytes()
        digest = base64.b64encode(hashlib.md5(data).digest()).decode()
        if metadata is None or metadata.get("md5Hash") != digest or metadata.get("contentType") != "application/pdf":
            raise DocumentError(f"Stored lease differs from this bundle: {entry['site_id']}. Existing content was preserved. Use the matching workshop version or arrange an explicit organizer update.")

    def upload(self, project_number):
        if self.inspect(project_number) is None:
            self.cloud.request("POST", "https://storage.googleapis.com/storage/v1/b?" + urlencode({"project": self.cloud.project}), {
                "name": self.bucket, "location": self.region,
                "labels": {"managed-by": "data-cloud-creator", "datacloud": "workshop"},
                "iamConfiguration": {"uniformBucketLevelAccess": {"enabled": True}, "publicAccessPrevention": "enforced"},
            })
        for entry in self.documents:
            metadata = self.cloud.get(self.object_url(entry["filename"]))
            if metadata is None:
                params = {"uploadType": "media", "name": entry["filename"], "ifGenerationMatch": "0"}
                url = "https://storage.googleapis.com/upload/storage/v1/b/" + self.bucket + "/o?" + urlencode(params)
                try:
                    metadata = self.cloud.request("POST", url, (self.bundle / entry["filename"]).read_bytes(), content_type="application/pdf")
                except Exception as exc:
                    # A concurrent create is safe only if it produced exactly
                    # the expected document. Never retry uncertain writes.
                    if getattr(exc, "status", None) != 412:
                        raise
                    metadata = self.cloud.get(self.object_url(entry["filename"]))
            self.check_object(entry, metadata)
        self.verify()

    def verify(self):
        objects, page = {}, None
        while True:
            params = {"prefix": "leases/"}
            if page:
                params["pageToken"] = page
            response = self.cloud.request("GET", self.url + "/o?" + urlencode(params))
            objects.update({obj["name"]: obj for obj in response.get("items", [])})
            page = response.get("nextPageToken")
            if not page:
                break
        if set(objects) != {entry["filename"] for entry in self.documents}:
            raise DocumentError("Documents bucket must contain exactly the 12 expected leases under leases/. Content was preserved; inspect missing or extra documents.")
        for entry in self.documents:
            self.check_object(entry, objects[entry["filename"]])


def main():
    # Import here to keep bundle generation entirely offline and independent
    # of provisioning. The shared Cloud client keeps credentials out of logs.
    from provision import Cloud, ProvisionError
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("upload", "verify"))
    parser.add_argument("project_id")
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--region", default="us-central1")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z][a-z0-9-]{4,28}[a-z0-9]", args.project_id):
        parser.error("Invalid project ID.")
    try:
        cloud = Cloud(args.project_id)
        store = DocumentStore(cloud, args.bundle, args.region)
        number = json.loads(cloud.gcloud("projects", "describe", args.project_id, "--format=json"))["projectNumber"]
        if args.action == "upload":
            store.upload(number)
        else:
            store.inspect(number)
            store.verify()
        print(f"Verified {len(store.documents)} leases in gs://{store.bucket}/leases/")
    except (DocumentError, ProvisionError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except Exception:
        print("Document operation failed; check the bundle, project access and cloud resource status. No response content was logged.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
