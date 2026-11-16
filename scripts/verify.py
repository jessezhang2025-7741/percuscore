#!/usr/bin/env python3
"""Run reproducible quick/full/release validation and retain an honest local report."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

from validation_support import (check_manual, compare_performance, file_hash,
                                manual_template, performance_values, run_check,
                                validation_lock, write_report)
from write_build_info import source_identity

ROOT = Path(__file__).resolve().parents[1]
FULL = ("app_build", "simulator_ready", "reader", "ui", "live_relaunch")
RELEASE = ("release_source", "fixture", "performance", "performance_comparison", "manual_device")


def capture(command, environment):
    try:
        result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=30)
        return result.stdout.strip() if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def snapshot(root, environment):
    identity = source_identity(root)
    digest = hashlib.sha256()
    try:
        if identity["source_state"] != "unavailable":
            names = subprocess.check_output(["git", "-C", str(root), "ls-files", "-c", "-o", "--exclude-standard", "-z"])
            files = sorted(set(path.decode() for path in names.split(b"\0") if path))
        else:
            files = sorted(str(path.relative_to(root)) for folder in ("Percuscore", "Sources", "Tests", "scripts", "Percuscore.xcodeproj")
                           for path in (root / folder).rglob("*") if path.is_file() and "__pycache__" not in path.parts and "xcuserdata" not in path.parts)
        for name in files:
            path = root / name
            digest.update(name.encode() + b"\0")
            if path.is_symlink():
                digest.update(os.readlink(path).encode())
            elif path.is_file():
                digest.update(bytes.fromhex(file_hash(path)))
            else:
                digest.update(b"missing")
        identity["fingerprint"] = digest.hexdigest()
    except (OSError, subprocess.CalledProcessError) as error:
        identity["fingerprint"] = None
        identity["fingerprint_error"] = str(error)
    project = capture(["plutil", "-convert", "json", "-o", "-", str(root / "Percuscore.xcodeproj/project.pbxproj")], environment)
    if project:
        objects = json.loads(project)["objects"]
        settings = next((obj["buildSettings"] for obj in objects.values() if obj.get("isa") == "XCBuildConfiguration"
                         and obj.get("name") == "Debug" and "PRODUCT_BUNDLE_IDENTIFIER" in obj.get("buildSettings", {})), {})
        identity.update(version=str(settings.get("MARKETING_VERSION", "unknown")), build=str(settings.get("CURRENT_PROJECT_VERSION", "unknown")))
    return identity


def choose_simulator(inventory, requested=None):
    candidates = []
    for runtime, devices in inventory.get("devices", {}).items():
        for device in devices:
            if device.get("isAvailable") and "iPad" in device.get("deviceTypeIdentifier", device.get("name", "")):
                candidates.append(dict(device, runtime=runtime))
    if requested:
        return next((device for device in candidates if device["udid"] == requested), None)
    booted = [device for device in candidates if device.get("state") == "Booted"]
    return sorted(booted or candidates, key=lambda device: (tuple(map(int, re.findall(r"\d+", device["runtime"]))), device["name"]), reverse=True)[0] if candidates else None


class Validator:
    def __init__(self, args, output):
        self.args, self.output = args, output
        controls = ("TOOLBAR_", "PERFORMANCE_", "VALIDATION_", "LARGE_PDF_BENCHMARK",
                    "TEST_RUNNER_TOOLBAR_", "TEST_RUNNER_PERFORMANCE_", "TEST_RUNNER_LARGE_PDF_")
        self.environment = {key: value for key, value in os.environ.items()
                            if not key.startswith(controls)}
        developer = args.developer_dir or os.environ.get("DEVELOPER_DIR")
        if not developer and Path("/Applications/Xcode.app/Contents/Developer").exists():
            developer = "/Applications/Xcode.app/Contents/Developer"
        if developer:
            developer = str(developer)
            self.environment["DEVELOPER_DIR"] = developer
        self.xcode = capture(["xcodebuild", "-version"], self.environment)
        self.swift = capture(["swift", "--version"], self.environment)
        self.device = None
        parameters = vars(args).copy()
        for key, value in parameters.items():
            if isinstance(value, Path):
                parameters[key] = str(value.resolve())
        self.report = {"format": "percuscore-validation-report", "format_version": 1,
                       "started_at_utc": datetime.now(timezone.utc).isoformat(), "level": args.level,
                       "source": snapshot(ROOT, self.environment), "parameters": parameters,
                       "environment": {"developer_dir": developer or capture(["xcode-select", "-p"], self.environment),
                                       "xcode": self.xcode, "swift": self.swift, "python": sys.version,
                                       "macos": capture(["sw_vers", "-productVersion"], self.environment),
                                       "architecture": platform.machine(), "simulator": None}, "checks": [],
                       "invocation": [sys.executable, str(ROOT / "scripts/verify.py"), *sys.argv[1:]], "report_directory": str(output)}
        self.cache = Path(tempfile.gettempdir()) / "Percuscore-validation-cache"
        self.checklist = ROOT / "docs/IPAD-CHECKLIST.md"
        self.check_ids = ["project", "scripts", "core"] + (list(FULL) if args.level != "quick" else []) + \
                         (list(RELEASE) if args.level == "release" else []) + ["source_consistency"]
        for identifier in self.check_ids:
            self.report["checks"].append({"id": identifier, "status": "not_run", "reason": "Not started"})
        self.save()

    def save(self):
        write_report(self.output, self.report)

    def set_result(self, result):
        index = next(i for i, check in enumerate(self.report["checks"]) if check["id"] == result["id"])
        self.report["checks"][index] = result
        self.save()
        print("[%s] %s: %s" % (result["status"], result["id"], result.get("reason", "")), flush=True)

    def skip(self, identifier, reason):
        self.set_result({"id": identifier, "status": "not_run", "reason": reason})

    def command(self, identifier, command, tests=False, prerequisite=None, environment=None):
        if self.args.plan:
            result = {"id": identifier, "status": "not_run", "reason": "Plan only; no checks executed",
                      "command": list(map(str, command)), "cwd": str(ROOT)}
        elif prerequisite:
            result = {"id": identifier, "status": "not_run", "reason": prerequisite,
                      "command": list(map(str, command)), "cwd": str(ROOT)}
        else:
            print("Running " + identifier + " …", flush=True)
            result = run_check(identifier, list(map(str, command)), ROOT, environment or self.environment,
                               self.output / (identifier + ".log"), tests=tests, timeout=self.args.timeout)
            if tests and "-resultBundlePath" in command:
                bundle = Path(command[command.index("-resultBundlePath") + 1])
                if bundle.exists():
                    summary = capture(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle), "--compact"], self.environment)
                    if summary:
                        data = json.loads(summary)
                        (self.output / (identifier + "-summary.json")).write_text(summary + "\n")
                        result["result_bundle"] = str(bundle)
                        result["tests"]["xcresult"] = {key: data.get(key) for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests", "testFailures", "runtimeWarnings")}
                        result["tests"].update(executed=data["totalTestCount"], failed=data["failedTests"], skipped=data["skippedTests"])
                        if result["exit_code"] == 0 and not result.get("interrupted"):
                            good = data["passedTests"] > 0 and data["failedTests"] == 0
                            result.update(status="passed" if good else "failed", reason="Executed tests verified from xcresult" if good else "xcresult contains no passed tests or reports failures")
        self.set_result(result)
        if result.get("interrupted"):
            raise KeyboardInterrupt
        return result

    def simulator(self):
        if self.args.plan:
            self.skip("simulator_ready", "Plan only; simulator not queried or booted")
            return
        inventory = capture(["xcrun", "simctl", "list", "devices", "available", "-j"], self.environment) if self.xcode else None
        self.device = choose_simulator(json.loads(inventory), self.args.simulator) if inventory else None
        if not self.device:
            self.skip("simulator_ready", "No available iPad simulator matched; install a runtime or specify --simulator")
            return
        runtimes = capture(["xcrun", "simctl", "list", "runtimes", "-j"], self.environment)
        if runtimes:
            runtime = next((item for item in json.loads(runtimes)["runtimes"] if item["identifier"] == self.device["runtime"]), {})
            self.device.update(runtime_version=runtime.get("version"), runtime_build=runtime.get("buildversion"))
        self.report["environment"]["simulator"] = self.device
        if self.device.get("state") != "Booted":
            boot = self.command("simulator_ready", ["xcrun", "simctl", "boot", self.device["udid"]])
            if boot["status"] != "passed":
                self.device = None
                return
        ready = self.command("simulator_ready", ["xcrun", "simctl", "bootstatus", self.device["udid"], "-b"])
        if ready["status"] != "passed":
            self.device = None

    def run(self):
        missing = None if self.xcode and self.swift else "Full Xcode/Swift toolchain unavailable"
        self.command("project", [sys.executable, ROOT / "scripts/check_project.py"], prerequisite=None if shutil.which("plutil") else "plutil unavailable")
        self.command("scripts", [sys.executable, "-m", "unittest", "discover", "-s", "scripts", "-p", "test_*.py", "-v"], tests=True)
        self.command("core", ["swift", "test", "--scratch-path", self.cache / "core"], tests=True, prerequisite=missing)
        if self.args.level != "quick":
            self.command("app_build", ["xcodebuild", "-project", "Percuscore.xcodeproj", "-scheme", "Percuscore", "-configuration", "Debug",
                         "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", self.cache / "app", "CODE_SIGNING_ALLOWED=NO", "build"], prerequisite=missing)
            self.simulator()
            device = self.device["udid"] if self.device else (self.args.simulator or "<available-iPad-simulator>")
            unavailable = missing or (None if self.device else "iPad simulator not ready")
            isolated = dict(self.environment, VALIDATION_READER_WORK=str(self.output / "work/reader"),
                            PERFORMANCE_SOURCE_ROOT=str(ROOT), PERFORMANCE_WORK=str(self.output / "work/ui"))
            self.command("reader", [sys.executable, ROOT / "scripts/run_reader_checks.py", device,
                         "-resultBundlePath", self.output / "reader.xcresult"], tests=True, prerequisite=unavailable, environment=isolated)
            self.command("ui", [sys.executable, ROOT / "scripts/run_toolbar_ui_checks.py", device,
                         "-skip-testing:ToolbarUITests/LargePDFPerformanceUITests", "-skip-testing:ToolbarUITests/LiveReaderRelaunchUITests",
                         "-resultBundlePath", self.output / "ui.xcresult"], tests=True, prerequisite=unavailable, environment=isolated)
            # Separate required check prevents an empty/filtered UI suite from claiming
            # that the production canvas and persistence path ran.
            self.command("live_relaunch", [sys.executable, ROOT / "scripts/run_toolbar_ui_checks.py", device,
                         "-only-testing:ToolbarUITests/LiveReaderRelaunchUITests", "-resultBundlePath", self.output / "live_relaunch.xcresult"],
                         tests=True, prerequisite=unavailable, environment=isolated)
        if self.args.level == "release":
            self.release()
        if self.args.plan:
            self.skip("source_consistency", "Plan only; no checks executed")
        else:
            after = snapshot(ROOT, self.environment)
            stable = bool(after.get("fingerprint")) and after == self.report["source"]
            self.set_result({"id": "source_consistency", "status": "passed" if stable else "failed",
                             "reason": "Source snapshot unchanged" if stable else "Source changed during validation; rerun for one consistent snapshot", "after": after})

    def release(self):
        if self.args.plan:
            for identifier in RELEASE:
                self.skip(identifier, "Plan only; no checks executed")
            return
        source = self.report["source"]
        clean = source.get("source_state") == "clean" and bool(source.get("fingerprint"))
        self.set_result({"id": "release_source", "status": "passed" if clean else "not_run",
                         "reason": "Clean committed source" if clean else "Release acceptance requires clean committed source"})
        template = manual_template(self.checklist, source)
        (self.output / "manual-device-template.json").write_text(json.dumps(template, ensure_ascii=False, indent=2) + "\n")
        if self.args.manual_record:
            try:
                record = json.loads(self.args.manual_record.read_text())
                self.report["parameters"]["manual_record_sha256"] = file_hash(self.args.manual_record)
                self.set_result(check_manual(record, self.checklist, source))
            except (OSError, ValueError, TypeError) as error:
                self.set_result({"id": "manual_device", "status": "failed", "reason": "Device evidence unreadable: " + str(error)})
        else:
            self.skip("manual_device", "No completed physical-device record; an unfilled template was generated")
        fixture = self.args.fixture
        if not fixture or not fixture.is_file():
            for identifier in ("fixture", "performance", "performance_comparison"):
                self.skip(identifier, "Provide the local 120-page/300-dpi fixture with --fixture")
            return
        identity = file_hash(fixture)
        self.report["parameters"].update(fixture_sha256=identity, fixture_bytes=fixture.stat().st_size)
        checked = self.command("fixture", ["swift", ROOT / "scripts/check_large_pdf_fixture.swift", fixture], prerequisite=None if self.xcode else "Full Xcode unavailable")
        blocked = "Fixture validation did not pass" if checked["status"] != "passed" else (None if self.device else "iPad simulator not ready")
        performance_env = dict(self.environment, PERFORMANCE_WORK=str(self.output / "work/performance"))
        measured = self.command("performance", [sys.executable, ROOT / "scripts/run_large_pdf_benchmark.py", "--fixture", fixture,
                    "--simulator", self.device["udid"] if self.device else "<available-iPad-simulator>", "--runs", str(self.args.runs),
                    "--glass", self.args.glass, "--output", self.output / "performance"], prerequisite=blocked, environment=performance_env)
        if measured["status"] != "passed":
            self.skip("performance_comparison", "Current performance measurement did not pass")
            return
        try:
            summary = json.loads((self.output / "performance/summary.json").read_text())
            if summary.get("fixture_sha256") != identity or summary.get("runs") != self.args.runs:
                raise ValueError("Benchmark summary fixture/run count mismatch")
            harness = hashlib.sha256()
            for name in ("scripts/run_large_pdf_benchmark.py", "scripts/large_pdf_benchmark_support.py", "scripts/large_pdf_benchmark_host.swift",
                         "scripts/run_toolbar_ui_checks.py", "Tests/PercuscoreUITests/LargePDFPerformanceUITests.swift"):
                harness.update(bytes.fromhex(file_hash(ROOT / name)))
            context = {"fixture_sha256": identity, "fixture_bytes": fixture.stat().st_size, "runs": self.args.runs, "glass": self.args.glass,
                       "simulator": {key: self.device.get(key) for key in ("udid", "name", "runtime", "runtime_version", "runtime_build", "deviceTypeIdentifier")},
                       "xcode": self.xcode, "swift": self.swift, "macos": self.report["environment"]["macos"],
                       "architecture": platform.machine(), "harness_sha256": harness.hexdigest(), "configuration": "Debug",
                       "diagnostics": "off",
                       "workload": "120 scan pages; 50 forward/50 backward turns; portrait; fresh app per run; system caches not flushed"}
            current = {"format": "percuscore-performance-record", "format_version": 1, "source": source, "context": context, "metrics": summary["metrics"]}
            performance_values(current)
            if file_hash(fixture) != identity:
                raise ValueError("Fixture changed during measurement")
            (self.output / "performance-record.json").write_text(json.dumps(current, indent=2, allow_nan=False) + "\n")
            baseline = json.loads(self.args.performance_baseline.read_text()) if self.args.performance_baseline else None
            limits = json.loads(self.args.performance_limits.read_text()) if self.args.performance_limits else None
            for key in ("performance_baseline", "performance_limits"):
                if getattr(self.args, key):
                    self.report["parameters"][key + "_sha256"] = file_hash(getattr(self.args, key))
            self.set_result(compare_performance(current, baseline, limits))
        except (OSError, ValueError, KeyError, TypeError) as error:
            self.set_result({"id": "performance_comparison", "status": "failed", "reason": "Performance evidence invalid: " + str(error)})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--level", choices=("quick", "full", "release"), default="quick")
    parser.add_argument("--output", type=Path, help="New empty output directory; defaults to ignored dist/validation/<run>")
    parser.add_argument("--simulator", help="Optional available iPad Simulator UUID; otherwise choose automatically")
    parser.add_argument("--developer-dir", type=Path)
    parser.add_argument("--fixture", type=Path)
    parser.add_argument("--performance-baseline", type=Path)
    parser.add_argument("--performance-limits", type=Path)
    parser.add_argument("--manual-record", type=Path)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--glass", choices=("on", "off"), default="on")
    parser.add_argument("--timeout", type=int, default=3600, help="Per-command timeout in seconds")
    parser.add_argument("--plan", action="store_true", help="Generate an incomplete command preview; execute no checks")
    args = parser.parse_args()
    if not 1 <= args.runs <= 20 or args.timeout < 1:
        parser.error("runs must be 1–20 and timeout positive")
    for key, value in vars(args).items():
        if isinstance(value, Path):
            setattr(args, key, value.expanduser().resolve())
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]
    output = args.output or ROOT / "dist/validation" / stamp
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        parser.error("Output directory is not empty; existing reports are never overwritten")
    output.mkdir(parents=True, exist_ok=True)
    validator = Validator(args, output)
    try:
        with validation_lock(Path(tempfile.gettempdir()) / "percuscore-validation.lock"):
            validator.run()
    except KeyboardInterrupt:
        validator.report["interrupted"] = True
        for check in validator.report["checks"]:
            if check.get("reason") == "Not started":
                check["reason"] = "Not run because validation was interrupted"
    except RuntimeError as error:
        validator.report["blocking_reason"] = str(error)
    except Exception as error:
        validator.report["checks"].append({"id": "runner", "status": "failed", "reason": type(error).__name__ + ": " + str(error)})
    finally:
        validator.report["finished_at_utc"] = datetime.now(timezone.utc).isoformat()
        validator.save()
    print("Report: " + str(output / "report.md"))
    print("Result: " + validator.report["overall"])
    return {"passed": 0, "failed": 1, "incomplete": 2}[validator.report["overall"]]


if __name__ == "__main__":
    sys.exit(main())
