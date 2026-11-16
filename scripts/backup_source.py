#!/usr/bin/env python3
"""Export a clean source commit and Git history outside the working checkout."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from write_build_info import source_identity


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def export(root, output):
    root, output = root.resolve(), output.resolve()
    if output == root or root in output.parents:
        raise ValueError("Choose an output directory outside this repository.")
    identity = source_identity(root)
    if identity["source_state"] != "clean":
        raise ValueError("Source backup requires a clean, committed Git checkout. Commit your changes first.")
    commit = identity["commit"]
    prefix = "Percuscore-source-" + commit[:12]
    names = {"bundle": prefix + ".bundle", "source_zip": prefix + ".zip"}
    manifest_name = prefix + ".json"
    if any((output / name).exists() for name in [*names.values(), manifest_name]):
        raise ValueError("A backup for this commit already exists; nothing was overwritten.")
    output.mkdir(parents=True, exist_ok=True)
    published = []

    def git(*args):
        return subprocess.run(["git", "-C", str(root), *args], check=True,
                              capture_output=True, text=True)

    try:
        with tempfile.TemporaryDirectory(prefix=".percuscore-source-", dir=output) as staging:
            staging = Path(staging)
            bundle = staging / names["bundle"]
            # Include branches and tags, not private stash/other auxiliary refs.
            git("bundle", "create", str(bundle), "HEAD", "--branches", "--tags")
            git("bundle", "verify", str(bundle))
            git("archive", "--format=zip", "--prefix=Percuscore/",
                "--output=" + str(staging / names["source_zip"]), commit)
            if source_identity(root) != identity:
                raise ValueError("Source changed during backup; no completed backup was published.")
            manifest = {
                "format": "percuscore-source-backup", "format_version": 1,
                "commit": commit, "created_at_utc": datetime.now(timezone.utc).isoformat(),
                "source_state": "clean", "device_acceptance": "not_asserted",
                "artifacts": {kind: {"file": name, "sha256": sha256(staging / name)}
                              for kind, name in names.items()},
            }
            (staging / manifest_name).write_text(json.dumps(manifest, indent=2) + "\n")
            # Exclusive creation prevents overwrites on APFS and removable FAT/exFAT
            # volumes alike. Publish the manifest last as the completion marker.
            for name in [*names.values(), manifest_name]:
                destination = output / name
                with destination.open("xb") as target:
                    published.append(destination)
                    with (staging / name).open("rb") as source:
                        shutil.copyfileobj(source, target, 1024 * 1024)
                    target.flush()
                    os.fsync(target.fileno())
    except Exception:
        for path in reversed(published):
            path.unlink()
        raise
    return output / manifest_name


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    try:
        print(export(args.root, args.output_dir))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print("Source backup failed: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
