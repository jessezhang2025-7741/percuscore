"""Missing destinations must fail before creating disposable test workspaces."""
import os
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent


class ExplicitSimulatorTests(unittest.TestCase):
    def check_missing_destination(self, name, work_variable):
        with tempfile.TemporaryDirectory(prefix="percuscore-cli-") as temporary:
            root = Path(temporary)
            scripts = root / "scripts"
            scripts.mkdir()
            script = scripts / name
            shutil.copy2(SCRIPTS / name, script)
            work = root / "must-not-be-created"
            environment = dict(os.environ)
            environment[work_variable] = str(work)
            result = subprocess.run([sys.executable, str(script)], cwd=root,
                                    env=environment, capture_output=True,
                                    text=True, timeout=20)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("SIMULATOR", (result.stdout + result.stderr).upper())
            self.assertFalse(work.exists(), "Missing destination must fail before copying or deleting a test workspace")

    def test_reader_requires_destination_before_touching_workspace(self):
        self.check_missing_destination("run_reader_checks.py", "VALIDATION_READER_WORK")

    def test_toolbar_requires_destination_before_touching_workspace(self):
        self.check_missing_destination("run_toolbar_ui_checks.py", "PERFORMANCE_WORK")

    def check_explicit_destination(self, name, work_variable):
        with tempfile.TemporaryDirectory(prefix="percuscore-cli-") as temporary:
            root = Path(temporary)
            tools = root / "tools"
            tools.mkdir()
            command = tools / "xcodebuild"
            command.write_text("#!/usr/bin/python3\nimport json, os, sys\nfrom pathlib import Path\nPath(os.environ['CLI_CAPTURE']).write_text(json.dumps(sys.argv[1:]))\n")
            command.chmod(0o755)
            capture = root / "invocation.json"
            environment = {k: v for k, v in os.environ.items()
                           if not k.startswith(("PERFORMANCE_", "TOOLBAR_", "VALIDATION_", "LARGE_PDF_"))}
            environment.update({work_variable: str(root / "test-work"),
                                "CLI_CAPTURE": str(capture),
                                "PATH": str(tools) + os.pathsep + os.environ.get("PATH", "")})
            device = "11111111-2222-4333-8444-555555555555"
            forwarded = "-only-testing:ExampleTests/OneCase"
            result = subprocess.run([sys.executable, str(SCRIPTS / name), device, forwarded],
                                    cwd=root, env=environment, capture_output=True,
                                    text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            arguments = json.loads(capture.read_text())
            self.assertEqual(arguments[arguments.index("-destination") + 1],
                             "platform=iOS Simulator,id=11111111-2222-4333-8444-555555555555")
            self.assertEqual(arguments[-1], forwarded)
            self.assertIn("CODE_SIGNING_ALLOWED=NO", arguments)

    def test_reader_forwards_explicit_destination_and_test_filter(self):
        self.check_explicit_destination("run_reader_checks.py", "VALIDATION_READER_WORK")

    def test_toolbar_forwards_explicit_destination_and_test_filter(self):
        self.check_explicit_destination("run_toolbar_ui_checks.py", "PERFORMANCE_WORK")


if __name__ == "__main__":
    unittest.main()
