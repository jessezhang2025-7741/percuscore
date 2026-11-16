#!/usr/bin/env python3
"""Package the exact clean source commit; exclude local files and diagnostics."""
from pathlib import Path
import subprocess
import sys

from write_build_info import source_identity

root = Path(__file__).resolve().parents[1]
identity = source_identity(root)
if identity["source_state"] != "clean":
    sys.exit("Source package requires a clean, committed Git checkout.")
dist = root / "dist"
dist.mkdir(exist_ok=True)
archive = dist / ("Percuscore-source-" + identity["commit"][:12] + ".zip")
created = False
try:
    with archive.open("xb") as stream:
        created = True
        subprocess.run(["git", "-C", str(root), "archive", "--format=zip",
                        "--prefix=Percuscore/", identity["commit"]], stdout=stream, check=True)
    print(archive)
except (OSError, subprocess.CalledProcessError) as error:
    if created:
        archive.unlink()
    sys.exit("Source package failed: " + str(error))
