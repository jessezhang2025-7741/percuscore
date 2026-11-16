"""Integration checks use real temporary Git repositories and restored bundles."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

SCRIPTS = Path(__file__).resolve().parent


class VersioningTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="percuscore-version-tests-")
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name) / "repo with spaces"
        self.root.mkdir()
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Version Test")
        self.git("config", "user.email", "version-test@example.invalid")
        (self.root / ".gitignore").write_text("*.pdf\n*.log\ndist/\n")
        (self.root / "source.txt").write_text("original source\n")
        self.git("add", ".")
        self.git("commit", "-m", "Initial fixture")
        self.commit = self.git("rev-parse", "HEAD").stdout.strip()

    def git(self, *args, cwd=None):
        return subprocess.run(["git", "-C", str(cwd or self.root), *args],
                              check=True, text=True, capture_output=True)

    def run_script(self, name, *args, **kwargs):
        return subprocess.run([sys.executable, str(SCRIPTS / name), *map(str, args)],
                              text=True, capture_output=True, **kwargs)

    def metadata(self, root=None):
        output = Path(self.work.name) / "built app" / "BuildInfo.plist"
        result = self.run_script("write_build_info.py", "--root", root or self.root,
                                 "--output", output, "--version", "0.2.0", "--build", "7")
        self.assertEqual(result.returncode, 0, result.stderr)
        return plistlib.loads(output.read_bytes())

    def test_clean_build_records_exact_commit_and_version(self):
        info = self.metadata()
        self.assertEqual(info["commit"], self.commit)
        self.assertEqual(info["source_state"], "clean")
        self.assertEqual((info["version"], info["build"]), ("0.2.0", "7"))

    def test_edited_and_untracked_sources_are_both_modified(self):
        (self.root / "new.swift").write_text("// untracked\n")
        self.assertEqual(self.metadata()["source_state"], "modified")
        (self.root / "new.swift").unlink()
        (self.root / "source.txt").write_text("edited\n")
        self.assertEqual(self.metadata()["source_state"], "modified")
        self.git("add", "source.txt")
        self.assertEqual(self.metadata()["source_state"], "modified")

    def test_ignored_personal_data_does_not_change_source_state(self):
        (self.root / "private-score.pdf").write_bytes(b"private score")
        (self.root / "device.log").write_text("private diagnostic")
        self.assertEqual(self.metadata()["source_state"], "clean")

    def test_copied_folder_never_borrows_parent_repository_identity(self):
        child = self.root / "copied-host"
        child.mkdir()
        info = self.metadata(child)
        self.assertEqual(info["source_state"], "unavailable")
        self.assertEqual(info["commit"], "")

    def test_unborn_repository_has_explicit_unknown_metadata(self):
        empty = Path(self.work.name) / "empty"
        empty.mkdir()
        self.git("init", cwd=empty)
        self.assertEqual(self.metadata(empty)["source_state"], "unavailable")

    def backup(self, output=None):
        return self.run_script("backup_source.py", "--root", self.root,
                               "--output-dir", output or Path(self.work.name) / "backups")

    def test_bundle_restores_commit_history_and_tag_without_private_data(self):
        self.git("tag", "baseline/test")
        (self.root / "source.txt").write_text("second revision\n")
        self.git("commit", "-am", "Second fixture")
        commit = self.git("rev-parse", "HEAD").stdout.strip()
        (self.root / "private-score.pdf").write_bytes(b"private score")
        output = Path(self.work.name) / "backups"
        result = self.backup(output)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(next(output.glob("*.json")).read_text())
        self.assertEqual(manifest["commit"], commit)
        for item in manifest["artifacts"].values():
            self.assertEqual(hashlib.sha256((output / item["file"]).read_bytes()).hexdigest(), item["sha256"])
        bundle = output / manifest["artifacts"]["bundle"]["file"]
        restored = Path(self.work.name) / "restored"
        self.git("clone", str(bundle), str(restored))
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=restored).stdout.strip(), commit)
        self.assertEqual(self.git("rev-list", "--count", "HEAD", cwd=restored).stdout.strip(), "2")
        self.assertEqual(self.git("rev-parse", "baseline/test", cwd=restored).stdout.strip(), self.commit)
        self.assertFalse((restored / "private-score.pdf").exists())
        with zipfile.ZipFile(output / manifest["artifacts"]["source_zip"]["file"]) as archive:
            self.assertEqual(archive.read("Percuscore/source.txt"), b"second revision\n")
            self.assertNotIn("Percuscore/private-score.pdf", archive.namelist())

    def test_backup_rejects_dirty_source_before_creating_artifacts(self):
        (self.root / "new.swift").write_text("uncommitted")
        output = Path(self.work.name) / "dirty-backup"
        result = self.backup(output)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("clean", result.stderr.lower())
        self.assertFalse(output.exists())

    def test_backup_rejects_output_inside_checkout_including_symlink(self):
        for output in (self.root / "backups", Path(self.work.name) / "linked"):
            if output.name == "linked":
                output.symlink_to(self.root, target_is_directory=True)
            result = self.backup(output)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("outside", result.stderr.lower())

    def test_existing_backup_is_never_overwritten(self):
        output = Path(self.work.name) / "backups"
        result = self.backup(output)
        self.assertEqual(result.returncode, 0, result.stderr)
        before = {p.name: p.read_bytes() for p in output.iterdir()}
        result = self.backup(output)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(before, {p.name: p.read_bytes() for p in output.iterdir()})

    def test_publish_failure_removes_new_artifacts_and_preserves_existing_file(self):
        output = Path(self.work.name) / "backups"
        output.mkdir()
        existing = output / ("Percuscore-source-" + self.commit[:12] + ".json")
        existing.symlink_to(output / "missing-target")
        result = self.backup(output)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(existing.is_symlink())
        self.assertEqual(list(output.iterdir()), [existing])

    def test_linked_git_worktree_has_its_own_correct_identity(self):
        worktree = Path(self.work.name) / "worktree"
        self.git("worktree", "add", "--detach", str(worktree), self.commit)
        info = self.metadata(worktree)
        self.assertEqual(info["commit"], self.commit)
        self.assertEqual(info["source_state"], "clean")

    def prepare_package_script(self):
        (self.root / "scripts").mkdir()
        for name in ("package_release.py", "write_build_info.py"):
            shutil.copy2(SCRIPTS / name, self.root / "scripts" / name)
        (self.root / "docs").mkdir()
        (self.root / "docs/private-device.log").write_text("private diagnostic")
        (self.root / "README.md").write_text("Fixture\n")
        self.git("add", ".")
        self.git("commit", "-m", "Add package fixture")
        return self.root / "scripts/package_release.py"

    def test_existing_package_entrypoint_excludes_ignored_diagnostics(self):
        script = self.prepare_package_script()
        result = subprocess.run([sys.executable, str(script)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        with zipfile.ZipFile(Path(result.stdout.strip())) as archive:
            self.assertNotIn("Percuscore/docs/private-device.log", archive.namelist())
            self.assertEqual(archive.read("Percuscore/source.txt"), b"original source\n")

    def test_existing_package_entrypoint_rejects_uncommitted_source(self):
        script = self.prepare_package_script()
        (self.root / "source.txt").write_text("uncommitted")
        result = subprocess.run([sys.executable, str(script)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "dist").exists())

    def test_generator_preserves_custom_versions_and_signing(self):
        project = self.root / "Percuscore.xcodeproj"
        project.mkdir()
        configs = {"debug": {"isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": {
            "MARKETING_VERSION": "0.3.2", "CURRENT_PROJECT_VERSION": "42",
            "DEVELOPMENT_TEAM": "TESTTEAM", "PRODUCT_BUNDLE_IDENTIFIER": "example.private.reader"}}}
        objects = dict(configs, project={"targets": ["target"]}, target={"name": "Percuscore", "buildConfigurationList": "list"},
                       list={"buildConfigurations": ["debug"]})
        (project / "project.pbxproj").write_bytes(plistlib.dumps({"rootObject": "project", "objects": objects}))
        (self.root / "scripts").mkdir()
        (self.root / "Percuscore/Resources").mkdir(parents=True)
        (self.root / "Percuscore/Fixture.swift").write_text("import Foundation\n")
        script = self.root / "scripts/generate_project.py"
        shutil.copy2(SCRIPTS / "generate_project.py", script)
        result = subprocess.run([sys.executable, str(script)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        regenerated = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(project / "project.pbxproj")]))
        debug = next(x["buildSettings"] for x in regenerated["objects"].values()
                     if x.get("isa") == "XCBuildConfiguration" and x.get("name") == "Debug"
                     and x.get("buildSettings", {}).get("PRODUCT_BUNDLE_IDENTIFIER") == "example.private.reader")
        self.assertEqual(debug["MARKETING_VERSION"], "0.3.2")
        self.assertEqual(debug["CURRENT_PROJECT_VERSION"], "42")
        self.assertEqual(debug["DEVELOPMENT_TEAM"], "TESTTEAM")


if __name__ == "__main__":
    unittest.main()
