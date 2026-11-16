#!/usr/bin/env python3
"""Write Git identity into the built app, never into the source checkout."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile


def source_identity(root):
    root = Path(root).resolve()
    environment = dict(os.environ, GIT_OPTIONAL_LOCKS="0")

    def git(*args):
        return subprocess.check_output(["git", "-C", str(root), *args],
                                       env=environment, stderr=subprocess.DEVNULL, text=True).strip()

    try:
        # Copied UI hosts and source ZIPs must not inherit an ancestor's identity.
        if Path(git("rev-parse", "--show-toplevel")).resolve() != root:
            return {"commit": "", "source_state": "unavailable"}
        commit = git("rev-parse", "--verify", "HEAD")
        modified = bool(git("status", "--porcelain=v1", "--untracked-files=normal"))
        return {"commit": commit, "source_state": "modified" if modified else "clean"}
    except (OSError, subprocess.CalledProcessError):
        return {"commit": "", "source_state": "unavailable"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", default=os.environ.get("MARKETING_VERSION", "unknown"))
    parser.add_argument("--build", default=os.environ.get("CURRENT_PROJECT_VERSION", "unknown"))
    args = parser.parse_args()
    info = dict(source_identity(args.root), format_version=1, version=args.version, build=args.build)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # Do not leave a partially written resource if the build is interrupted.
    descriptor, temporary = tempfile.mkstemp(dir=args.output.parent, prefix=".build-info-")
    try:
        with os.fdopen(descriptor, "wb") as stream:
            plistlib.dump(info, stream)
        os.replace(temporary, args.output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == "__main__":
    main()
