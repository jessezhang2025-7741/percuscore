"""Small, testable primitives for honest local validation and evidence checks."""
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import time


def overall(checks):
    states = [check["status"] for check in checks]
    if "failed" in states:
        return "failed"
    return "passed" if states and all(state == "passed" for state in states) else "incomplete"


def file_hash(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def parse_tests(log, partial=False):
    counts = {"executed": 0, "failed": 0, "skipped": 0, "failures": []}
    summaries = re.findall(r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?", log)
    if summaries:
        total, skipped, failed = summaries[-1]
        counts.update(executed=int(total), failed=int(failed), skipped=int(skipped or 0))
    else:
        python = re.findall(r"Ran (\d+) tests? in", log)
        if python:
            counts["executed"] = int(python[-1])
            endings = re.findall(r"(?:FAILED|OK)\s*\(([^)]+)\)", log)
            if endings:
                values = dict(re.findall(r"(failures|errors|skipped)=(\d+)", endings[-1]))
                counts["failed"] = int(values.get("failures", 0)) + int(values.get("errors", 0))
                counts["skipped"] = int(values.get("skipped", 0))
    if partial:
        finished = re.findall(r"Test [Cc]ase .*? (passed|failed|skipped) \(", log)
        counts.update(executed=len(finished), failed=finished.count("failed"),
                      skipped=finished.count("skipped"), partial=True)
    counts["failures"] = [line.strip() for line in log.splitlines()
                          if re.search(r"^(FAIL|ERROR):|Test [Cc]ase .*failed|error:.*(?:XCTAssert|XCTFail)", line)][:40]
    return counts


def stop_process_group(process):
    """Best-effort bounded cleanup; never equate parent exit with tree exit."""
    cleanup = {"confirmed": False, "process_group": process.pid, "errors": []}
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            pass
        except OSError as error:
            cleanup["errors"].append("Group %s: %s" % (sig.name, error))
            # Direct child cleanup can still succeed when group signalling is denied.
            try:
                process.kill()
            except OSError as child_error:
                cleanup["errors"].append("Parent kill: " + str(child_error))
        try:
            process.wait(timeout=5)
        except (subprocess.TimeoutExpired, OSError) as error:
            cleanup["errors"].append("Parent wait: " + str(error))
    deadline = time.monotonic() + 1
    while True:
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            cleanup["confirmed"] = True
            break
        except OSError as error:
            cleanup["errors"].append("Group exit verification: " + str(error))
            break
        if time.monotonic() >= deadline:
            break
        time.sleep(0.05)
    return cleanup


def run_check(identifier, command, cwd, environment, log, tests=False, timeout=1800):
    start = time.monotonic()
    result = {"id": identifier, "status": "failed", "command": [str(x) for x in command],
              "cwd": str(cwd), "log": str(log), "reason": "", "exit_code": None}
    log.parent.mkdir(parents=True, exist_ok=True)
    process = None
    interrupted = False
    partial = False
    try:
        with log.open("w") as output:
            process = subprocess.Popen(command, cwd=cwd, env=environment, stdout=output,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                result["exit_code"] = process.wait(timeout=timeout)
            except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
                interrupted = isinstance(error, KeyboardInterrupt)
                partial = True
                result["reason"] = "Interrupted" if interrupted else "Timeout"
                result["cleanup"] = stop_process_group(process)
                result["reason"] += ("; process group exit confirmed" if result["cleanup"]["confirmed"]
                                     else "; descendant cleanup unconfirmed; further commands blocked")

    except FileNotFoundError as error:
        result.update(status="not_run", reason="Missing executable or working directory: " + str(error))
    except OSError as error:
        result["reason"] = str(error)
    if process and not result["reason"]:
        result["status"] = "passed" if result["exit_code"] == 0 else "failed"
        result["reason"] = "Completed" if result["exit_code"] == 0 else "Command exited with " + str(result["exit_code"])
    if tests:
        result["tests"] = parse_tests(log.read_text(errors="replace"), partial=partial)
        counts = result["tests"]
        if result["status"] == "passed" and (counts["executed"] <= counts["skipped"] or counts["failed"]):
            result.update(status="failed", reason="No successful executed tests, or test failures were reported")
    result["elapsed_seconds"] = round(time.monotonic() - start, 3)
    if interrupted:
        result["interrupted"] = True
    return result


@contextmanager
def validation_lock(path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as stream:
        try:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another validation run holds the simulator lock; retry after it finishes")
        try:
            yield
        finally:
            fcntl.flock(stream.fileno(), fcntl.LOCK_UN)


def performance_values(record):
    if record.get("format") != "percuscore-performance-record" or not record.get("context"):
        raise ValueError("Missing comparable performance record/context")
    values = {key: record["metrics"][key][stat] for key, stat in
              (("open_ms", "median"), ("turn_tile_ms", "p95"), ("peak_bytes", "median"))}
    if any(isinstance(value, bool) or not isinstance(value, (int, float)) or
           not math.isfinite(value) or value <= 0 for value in values.values()):
        raise ValueError("Performance measurements must be finite and positive")
    return values


def compare_performance(current, baseline, limits):
    result = {"id": "performance_comparison", "status": "not_run", "reason": "No performance baseline supplied"}
    try:
        values = performance_values(current)
        if baseline is None:
            return result
        previous = performance_values(baseline)
        if current["context"] != baseline["context"]:
            result["reason"] = "Baseline conditions differ (fixture, simulator, toolchain, runs or harness); comparison not performed"
            return result
        changes = {key: (values[key] / previous[key] - 1) * 100 for key in values}
        result["changes_percent"] = changes
        if limits is None:
            result["reason"] = "Trend recorded; release limits have not been configured"
            return result
        if set(limits) != set(values) or any(isinstance(v, bool) or not isinstance(v, (int, float)) or
                                            not math.isfinite(v) or v < 0 for v in limits.values()):
            raise ValueError("Configure finite nonnegative percentage limits for all three metrics")
        regressions = [key for key in changes if changes[key] > limits[key] + 1e-9]
        result.update(status="failed" if regressions else "passed",
                      reason="Regression exceeded limits: " + ", ".join(regressions) if regressions else "Comparable measurements are within configured limits",
                      limits_percent=limits)
    except (KeyError, TypeError, ValueError) as error:
        result.update(status="failed", reason="Invalid performance evidence: " + str(error))
    return result


def manual_template(checklist, source):
    items = re.findall(r"^- \[[ xX]\] (.+)$", checklist.read_text(), re.MULTILINE)
    return {"format": "percuscore-device-acceptance", "format_version": 1,
            "source": json.loads(json.dumps(source)), "checklist_sha256": file_hash(checklist), "operator": "", "tested_at": "",
            "device": {"model": "", "os": "", "pencil": "", "app_version": "", "app_build": ""},
            "checks": [{"id": "ipad-%03d" % (i + 1), "description": text, "status": "not_run", "notes": ""}
                       for i, text in enumerate(items)]}


def check_manual(record, checklist, source):
    result = {"id": "manual_device", "status": "not_run", "reason": "Actual device checklist is not completed"}
    try:
        expected = manual_template(checklist, source)
        if record.get("format") != expected["format"] or record.get("format_version") != 1:
            raise ValueError("Unknown manual evidence format")
        if (source.get("source_state") != "clean" or not source.get("commit") or
                record.get("source") != source or record.get("checklist_sha256") != expected["checklist_sha256"]):
            result["reason"] = "Device record does not match this clean source snapshot and checklist"
            return result
        checks = record["checks"]
        if not expected["checks"] or len(checks) != len(expected["checks"]) or \
                {item["id"] for item in checks} != {item["id"] for item in expected["checks"]}:
            raise ValueError("Missing or duplicate device checklist items")
        if any(item["status"] not in {"passed", "failed", "not_run"} for item in checks):
            raise ValueError("Unknown device item status")
        result["counts"] = {state: sum(item["status"] == state for item in checks) for state in ("passed", "failed", "not_run")}
        if result["counts"]["failed"]:
            result.update(status="failed", reason="Device checks failed", failures=[item for item in checks if item["status"] == "failed"])
        elif result["counts"]["not_run"] == 0:
            if not str(record.get("operator", "")).strip() or any(not str(record.get("device", {}).get(key, "")).strip()
                    for key in ("model", "os", "pencil", "app_version", "app_build")):
                return result
            stamp = datetime.fromisoformat(record["tested_at"].replace("Z", "+00:00"))
            if stamp.tzinfo is None:
                raise ValueError("Device test date must include timezone")
            for key, device_key in (("version", "app_version"), ("build", "app_build")):
                if source.get(key) and source[key] != record["device"][device_key]:
                    result["reason"] = "Installed device version/build differs from source"
                    return result
            result.update(status="passed", reason="Operator-supplied device checks match this snapshot; not an automatic physical-device test")
    except (KeyError, TypeError, ValueError) as error:
        result.update(status="failed", reason="Invalid device evidence: " + str(error))
    return result


def write_report(directory, report):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    report["overall"] = overall(report["checks"])
    report["updated_at_utc"] = datetime.now(timezone.utc).isoformat()
    payload = json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n"
    temporary = directory / ".report.json.tmp"
    temporary.write_text(payload)
    temporary.replace(directory / "report.json")
    labels = {"passed": "通过", "failed": "失败", "not_run": "未执行", "incomplete": "未完成"}
    lines = ["# Percuscore 本地验收报告", "", "结果：**%s** · 层级：%s" % (labels[report["overall"]], report["level"]),
             "", "源码：`%s` · %s" % (report["source"].get("commit") or "不可用", report["source"].get("source_state", "unknown")),
             "", "| 检查 | 状态 | 说明 | 日志 |", "|---|---|---|---|"]
    for check in report["checks"]:
        log = "[日志](<%s>)" % check["log"] if check.get("log") else "—"
        reason = str(check.get("reason", "")).replace("|", "\\|").replace("\n", " ")
        lines.append("| %s | %s | %s | %s |" % (check["id"], labels.get(check["status"], check["status"]), reason, log))
    lines += ["", "## 测试数量与失败项目", ""]
    for check in report["checks"]:
        if "tests" in check:
            count = check["tests"]
            suffix = "（运行中断／超时，仅统计已结束测试；其他结果未知）" if count.get("partial") else ""
            lines.append("- %s：%s 项，失败 %s，跳过 %s。%s" % (check["id"], count["executed"], count["failed"], count["skipped"], suffix))
            lines.extend("  - " + failure for failure in count.get("failures", []))
    lines += ["", "## 重现信息", "", "完整环境、参数、样本及证据标识见同目录 report.json。", "", "```json",
              json.dumps({key: report.get(key) for key in ("source", "environment", "parameters")}, ensure_ascii=False, indent=2), "```", ""]
    for check in report["checks"]:
        if check.get("command"):
            lines += ["**%s**" % check["id"], "", "```sh", "cd " + shlex.quote(check.get("cwd", ".")),
                      shlex.join(check["command"]), "```", ""]
    (directory / "report.md").write_text("\n".join(lines))
