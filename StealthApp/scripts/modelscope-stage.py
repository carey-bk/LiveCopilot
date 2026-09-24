#!/usr/bin/env python3
"""Prepare the verified LiveCopilot download set for a ModelScope model repo.

This performs no network calls or account actions. Files are hard-linked from the
already verified OSS staging tree so installed models and user data are untouched.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = REPO / "docs/oss-model-manifest.json"
DEFAULT_SOURCE = REPO / "StealthApp/build/oss-stage/upload/models"
DEFAULT_DESTINATION = REPO / "StealthApp/build/modelscope-stage"


def sha256(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--destination", type=Path, default=DEFAULT_DESTINATION)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    objects = manifest["objects"]
    keys = [item["key"] for item in objects]
    if len(keys) != len(set(keys)):
        raise SystemExit("duplicate object keys in manifest")
    destination = args.destination.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    rows = []
    total = 0
    for item in objects:
        key = item["key"]
        if key.startswith("/") or ".." in Path(key).parts:
            raise SystemExit("unsafe object key: " + key)
        source = args.source / key
        if not source.is_file() or source.stat().st_size != item["size"] or sha256(source) != item["sha256"]:
            raise SystemExit("source failed size or SHA-256 validation: " + key)
        target = destination / key
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            if not target.is_file() or target.stat().st_size != item["size"] or sha256(target) != item["sha256"]:
                raise SystemExit("existing destination differs: " + key)
        else:
            os.link(source, target)
        total += item["size"]
        rows.append("| `" + key + "` | " + str(item["size"]) + " | `" + item["sha256"] + "` | " + item["license"] + " | [upstream](" + item["source"] + ") |")
    readme = "\n".join([
        "# LiveCopilot download artifacts",
        "",
        "This repository mirrors pinned, unmodified upstream files needed by the LiveCopilot macOS local-model installer. It contains no user data, credentials, or LiveCopilot session content. The upstream authors retain their respective rights. Each file is verified against the SHA-256 below before use; see each upstream source and any bundled LICENSE/NOTICE files for the applicable terms.",
        "",
        "The files below are independent artifacts with different licenses; the repository as a whole does not apply one license to all files. Python wheel license metadata is retained inside each archive. The tokenizers 0.23.2 wheel declares Apache Software License in its metadata but contains no full license text, so a copy of the standard Apache-2.0 terms is provided in `LICENSES/tokenizers-0.23.2-APACHE-2.0.txt`.",
        "",
        "| Path | Bytes | SHA-256 | License | Original source |",
        "| --- | ---: | --- | --- | --- |",
        *rows,
        "",
    ])
    (destination / "README.md").write_text(readme)
    (destination / "artifact-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    apache_text = (destination / "laya/model/LICENSE").read_bytes()
    if b"Apache License" not in apache_text[:100] or b"Version 2.0" not in apache_text[:100]:
        raise SystemExit("staged Apache-2.0 text is missing or unexpected")
    license_path = destination / "LICENSES/tokenizers-0.23.2-APACHE-2.0.txt"
    license_path.parent.mkdir(parents=True, exist_ok=True)
    license_path.write_bytes(apache_text)
    print("OK " + str(len(objects)) + " objects " + str(total) + " bytes at " + str(destination))


if __name__ == "__main__":
    main()
