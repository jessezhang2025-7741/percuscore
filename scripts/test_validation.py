"""Behavior checks for truthful validation reports and source-bound evidence."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parent


class ValidationTests(unittest.TestCase):
    def setUp(self):
        path = SCRIPTS / "validation_support.py"
        self.assertTrue(path.exists(), "Unified validation helpers are not implemented")
        spec = importlib.util.spec_from_file_location("validation_support", path)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.work = tempfile.TemporaryDirectory(prefix="percuscore-validation-tests-")
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)

    def test_not_run_prevents_an_all_passed_summary(self):
        self.assertEqual(self.module.overall([{"status": "passed"}, {"status": "not_run"}]), "incomplete")
        self.assertEqual(self.module.overall([]), "incomplete")

    def test_failure_dominates_missing_checks(self):
        self.assertEqual(self.module.overall([{"status": "not_run"}, {"status": "failed"}]), "failed")
        self.assertEqual(self.module.overall([{"status": "passed"}]), "passed")

    def test_xctest_count_uses_final_summary_not_sum_of_nested_suites(self):
        log = "Executed 2 tests, with 0 failures\nExecuted 5 tests, with 0 failures\nExecuted 7 tests, with 0 failures"
        self.assertEqual(self.module.parse_tests(log)["executed"], 7)

    def test_python_counts_and_failures_are_preserved(self):
        counts = self.module.parse_tests("FAIL: test_bad (suite.Test)\nRan 18 tests in 2s\nFAILED (failures=1)")
        self.assertEqual(counts["executed"], 18)
        self.assertEqual(counts["failed"], 1)
        self.assertIn("test_bad", " ".join(counts["failures"]))

    def test_interrupted_run_counts_completed_cases_instead_of_last_partial_suite(self):
        log = "Test Case 'a' passed (0.1 seconds).\nExecuted 1 test, with 0 failures\nTest Case 'b' failed (0.1 seconds).\nTest Case 'c' started."
        counts = self.module.parse_tests(log, partial=True)
        self.assertEqual((counts["executed"], counts["failed"], counts["skipped"]), (2, 1, 0))
        self.assertTrue(counts["partial"])

    def test_skips_and_failed_xctest_names_are_reported(self):
        log = "Test Case '-[ReaderTests.Test testLostInk]' failed (0.1 seconds).\nExecuted 3 tests, with 1 test skipped and 1 failure"
        counts = self.module.parse_tests(log)
        self.assertEqual((counts["executed"], counts["skipped"], counts["failed"]), (3, 1, 1))
        self.assertIn("testLostInk", " ".join(counts["failures"]))

    def test_zero_test_exit_success_is_not_a_passing_test_check(self):
        result = self.module.run_check("empty", [sys.executable, "-c", "print('no tests')"], self.root, dict(os.environ), self.root / "empty.log", tests=True)
        self.assertEqual(result["status"], "failed")
        self.assertIn("test", result["reason"].lower())

    def test_process_failure_and_log_location_are_preserved(self):
        result = self.module.run_check("bad", [sys.executable, "-c", "print('actual failure'); raise SystemExit(7)"], self.root, dict(os.environ), self.root / "bad.log")
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["exit_code"], 7)
        self.assertIn("actual failure", Path(result["log"]).read_text())

    def test_missing_executable_is_not_run(self):
        result = self.module.run_check("missing", ["/missing/percuscore-tool"], self.root, dict(os.environ), self.root / "missing.log")
        self.assertEqual(result["status"], "not_run")

    def test_timeout_fails_and_keeps_the_log(self):
        result = self.module.run_check("timeout", [sys.executable, "-c", "import time; print('started',flush=True); time.sleep(5)"], self.root, dict(os.environ), self.root / "timeout.log", timeout=0.2)
        self.assertEqual(result["status"], "failed")
        self.assertIn("timeout", result["reason"].lower())
        self.assertIn("started", Path(result["log"]).read_text())

    def test_denied_group_cleanup_preserves_timeout_and_partial_counts(self):
        code = "import time; print(\"Test Case 'a' passed (0.1 seconds).\\nExecuted 1 test, with 0 failures\\nTest Case 'b' passed (0.1 seconds).\", flush=True); time.sleep(2)"
        with mock.patch.object(self.module.os, "killpg", side_effect=PermissionError("denied")):
            result = self.module.run_check("denied", [sys.executable, "-c", code], self.root,
                                           dict(os.environ), self.root / "denied.log", tests=True, timeout=0.2)
        self.assertTrue(result["reason"].startswith("Timeout"), result)
        self.assertEqual(result["tests"]["executed"], 2)
        self.assertTrue(result["tests"]["partial"])
        self.assertFalse(result["cleanup"]["confirmed"])
        self.assertIn("descendant", result["reason"].lower())

    def test_cleanup_waits_are_bounded_even_when_kill_cannot_stop_parent(self):
        process = mock.Mock(pid=12345)
        def wait(timeout=None):
            self.assertIsNotNone(timeout, "Cleanup waited indefinitely")
            raise subprocess.TimeoutExpired("stuck", timeout)
        process.wait.side_effect = wait
        process.kill.side_effect = PermissionError("denied")
        with mock.patch.object(self.module.subprocess, "Popen", return_value=process), \
                mock.patch.object(self.module.os, "killpg", side_effect=PermissionError("denied")):
            result = self.module.run_check("stuck", ["stuck"], self.root, {}, self.root / "stuck.log", timeout=0.1)
        self.assertTrue(result["reason"].startswith("Timeout"), result)
        self.assertFalse(result["cleanup"]["confirmed"])

    def test_timeout_also_stops_a_descendant_ignoring_termination(self):
        pid_file = self.root / "child.pid"
        child = "import os,signal,time;from pathlib import Path;signal.signal(signal.SIGTERM,signal.SIG_IGN);Path(%r).write_text(str(os.getpid()));time.sleep(30)" % str(pid_file)
        parent = "import subprocess,sys,time;subprocess.Popen([sys.executable,'-c',%r]);time.sleep(30)" % child
        self.module.run_check("tree", [sys.executable, "-c", parent], self.root, dict(os.environ), self.root / "tree.log", timeout=0.5)
        self.assertTrue(pid_file.exists())
        pid = int(pid_file.read_text())
        def cleanup():
            try:
                os.kill(pid, 9)
            except ProcessLookupError:
                pass
        self.addCleanup(cleanup)
        state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], text=True, capture_output=True).stdout.strip()
        self.assertTrue(not state or state.startswith("Z"), "Timed-out descendant is still running: " + state)

    def test_second_process_cannot_acquire_simulator_lock(self):
        lock = self.root / "lock"
        with self.module.validation_lock(lock):
            code = "import sys;sys.path.insert(0,sys.argv[1]);from validation_support import validation_lock;from pathlib import Path\nwith validation_lock(Path(sys.argv[2])): pass"
            result = subprocess.run([sys.executable, "-c", code, str(SCRIPTS), str(lock)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
        with self.module.validation_lock(lock):
            pass

    def performance_record(self, scale=1):
        return {"format": "percuscore-performance-record", "context": {"fixture": "abc", "simulator": "device", "xcode": "27", "runs": 5},
                "metrics": {"open_ms": {"median": 100 * scale}, "turn_tile_ms": {"p95": 50 * scale}, "peak_bytes": {"median": 1000 * scale}}}

    def test_comparable_performance_with_explicit_limits_passes(self):
        result = self.module.compare_performance(self.performance_record(1.05), self.performance_record(), {"open_ms": 10, "turn_tile_ms": 10, "peak_bytes": 10})
        self.assertEqual(result["status"], "passed")
        self.assertAlmostEqual(result["changes_percent"]["open_ms"], 5)

    def test_performance_regression_fails_and_names_the_metric(self):
        result = self.module.compare_performance(self.performance_record(1.2), self.performance_record(), {"open_ms": 10, "turn_tile_ms": 10, "peak_bytes": 10})
        self.assertEqual(result["status"], "failed")
        self.assertIn("open_ms", result["reason"])

    def test_different_conditions_are_not_a_valid_comparison(self):
        baseline = self.performance_record()
        baseline["context"]["xcode"] = "26"
        self.assertEqual(self.module.compare_performance(self.performance_record(), baseline, {})["status"], "not_run")

    def test_missing_limits_produces_trends_but_cannot_pass_release(self):
        result = self.module.compare_performance(self.performance_record(1.1), self.performance_record(), None)
        self.assertEqual(result["status"], "not_run")
        self.assertIn("changes_percent", result)

    def test_invalid_nan_metrics_cannot_pass(self):
        record = self.performance_record()
        record["metrics"]["open_ms"]["median"] = float("nan")
        self.assertEqual(self.module.compare_performance(record, self.performance_record(), {"open_ms": 10})["status"], "failed")

    def test_missing_baseline_is_not_a_passing_comparison(self):
        self.assertEqual(self.module.compare_performance(self.performance_record(), None, None)["status"], "not_run")

    def manual_template(self):
        checklist = self.root / "checklist.md"
        checklist.write_text("# iPad\n- [ ] Draw then Done\n- [ ] Relaunch\n")
        source = {"commit": "abc123", "source_state": "clean", "fingerprint": "snapshot"}
        return self.module.manual_template(checklist, source), checklist, source

    def test_generated_manual_checklist_never_defaults_to_passed(self):
        record, checklist, source = self.manual_template()
        self.assertEqual(len(record["checks"]), 2)
        self.assertTrue(all(x["status"] == "not_run" for x in record["checks"]))
        self.assertEqual(self.module.check_manual(record, checklist, source)["status"], "not_run")

    def completed_manual(self):
        record, checklist, source = self.manual_template()
        record["operator"] = "Tester"
        record["tested_at"] = "2026-10-08T12:00:00-04:00"
        record["device"] = {"model": "iPad", "os": "27", "pencil": "Pencil", "app_version": "0.1.0", "app_build": "1"}
        for item in record["checks"]:
            item["status"] = "passed"
        return record, checklist, source

    def test_complete_matching_device_record_can_pass(self):
        record, checklist, source = self.completed_manual()
        self.assertEqual(self.module.check_manual(record, checklist, source)["status"], "passed")

    def test_stale_device_record_or_changed_checklist_is_not_run(self):
        record, checklist, source = self.completed_manual()
        source["commit"] = "different"
        self.assertEqual(self.module.check_manual(record, checklist, source)["status"], "not_run")
        source["commit"] = "abc123"
        checklist.write_text("- [ ] Different task\n")
        self.assertEqual(self.module.check_manual(record, checklist, source)["status"], "not_run")

    def test_missing_or_duplicate_manual_items_cannot_pass(self):
        record, checklist, source = self.completed_manual()
        record["checks"][1] = record["checks"][0]
        self.assertEqual(self.module.check_manual(record, checklist, source)["status"], "failed")

    def test_report_roundtrip_includes_missing_checks_and_commands(self):
        report = {"level": "full", "source": {"commit": "abc"}, "environment": {}, "parameters": {},
                  "checks": [{"id": "reader", "status": "not_run", "reason": "No simulator", "command": ["python3", "reader.py"]}]}
        self.module.write_report(self.root, report)
        saved = json.loads((self.root / "report.json").read_text())
        self.assertEqual(saved["overall"], "incomplete")
        self.assertIn("No simulator", (self.root / "report.md").read_text())
        self.assertEqual(saved["checks"][0]["command"], ["python3", "reader.py"])


class ProjectValidationTests(unittest.TestCase):
    def test_actual_project_rejects_a_missing_source_reference(self):
        checker = SCRIPTS / "check_project.py"
        self.assertTrue(checker.exists(), "Project validation is not implemented")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            # Use the real project metadata; all referenced files absent is invalid.
            (root / "Percuscore.xcodeproj").mkdir()
            (root / "Percuscore.xcodeproj/project.pbxproj").write_bytes((SCRIPTS.parent / "Percuscore.xcodeproj/project.pbxproj").read_bytes())
            result = subprocess.run([sys.executable, str(checker), "--root", str(root)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing", result.stdout.lower())


class EntrypointTests(unittest.TestCase):
    def test_unconfirmed_cleanup_blocks_later_commands_and_simulator_queries(self):
        sys.path.insert(0, str(SCRIPTS))
        import verify
        import argparse
        with tempfile.TemporaryDirectory() as directory:
            runner = verify.Validator(argparse.Namespace(developer_dir=None, level="full", plan=False,
                                                         timeout=1), Path(directory))
            failed = {"id": "ui", "status": "failed", "reason": "Timeout; descendants unconfirmed",
                      "exit_code": None, "cleanup": {"confirmed": False}}
            with mock.patch.object(verify, "run_check", return_value=failed):
                runner.command("ui", ["unused"])
            marker = Path(directory) / "must-not-run"
            result = runner.command("live_relaunch", [sys.executable, "-c", "from pathlib import Path; Path(%r).touch()" % str(marker)])
            self.assertFalse(marker.exists(), "Later process started after uncertain cleanup")
            self.assertEqual(result["status"], "not_run")
            with mock.patch.object(verify, "capture", side_effect=AssertionError("Simulator queried after uncertain cleanup")):
                runner.simulator()

    def test_release_without_inputs_keeps_required_evidence_unexecuted(self):
        sys.path.insert(0, str(SCRIPTS))
        import verify
        import argparse
        with tempfile.TemporaryDirectory() as directory:
            args = argparse.Namespace(developer_dir=None, level="release", plan=False,
                                      manual_record=None, fixture=None)
            runner = verify.Validator(args, Path(directory))
            runner.release()
            states = {check["id"]: check["status"] for check in runner.report["checks"]}
            for identifier in ("manual_device", "fixture", "performance", "performance_comparison"):
                self.assertEqual(states[identifier], "not_run")
            self.assertEqual(runner.report["overall"], "incomplete")
            template = json.loads((Path(directory) / "manual-device-template.json").read_text())
            self.assertTrue(template["checks"])
            self.assertTrue(all(item["status"] == "not_run" for item in template["checks"]))

    def test_inherited_test_source_and_benchmark_controls_are_cleared(self):
        sys.path.insert(0, str(SCRIPTS))
        import verify
        import argparse
        with tempfile.TemporaryDirectory() as directory:
            args = argparse.Namespace(developer_dir=None, level="full", output=Path(directory))
            original = {key: os.environ.get(key) for key in ("PERFORMANCE_SOURCE_ROOT", "LARGE_PDF_BENCHMARK")}
            try:
                os.environ["PERFORMANCE_SOURCE_ROOT"] = "/different/checkout"
                os.environ["LARGE_PDF_BENCHMARK"] = "1"
                runner = verify.Validator(args, Path(directory))
                self.assertFalse("PERFORMANCE_SOURCE_ROOT" in runner.environment)
                self.assertFalse("LARGE_PDF_BENCHMARK" in runner.environment)
            finally:
                for key, value in original.items():
                    if value is None:
                        os.environ.pop(key, None)
                    else:
                        os.environ[key] = value

    def test_release_plan_reports_every_unexecuted_requirement(self):
        entry = SCRIPTS / "verify.py"
        self.assertTrue(entry.exists(), "Unified entrypoint is not implemented")
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "report"
            result = subprocess.run([sys.executable, str(entry), "--level", "release", "--plan", "--output", str(output)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2, result.stderr)
            report = json.loads((output / "report.json").read_text())
            self.assertEqual(report["overall"], "incomplete")
            required = {"core", "project", "scripts", "app_build", "reader", "ui", "live_relaunch", "performance", "performance_comparison", "manual_device"}
            self.assertTrue(required <= {check["id"] for check in report["checks"]})
            self.assertTrue(all(check["status"] == "not_run" for check in report["checks"]))

    def test_existing_report_directory_is_never_overwritten(self):
        entry = SCRIPTS / "verify.py"
        self.assertTrue(entry.exists(), "Unified entrypoint is not implemented")
        with tempfile.TemporaryDirectory() as directory:
            sentinel = Path(directory) / "report.json"
            sentinel.write_text("keep this report")
            result = subprocess.run([sys.executable, str(entry), "--plan", "--output", directory], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(sentinel.read_text(), "keep this report")


if __name__ == "__main__":
    unittest.main()
