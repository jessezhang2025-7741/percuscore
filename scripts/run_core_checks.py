#!/usr/bin/env python3
"""Run unchanged XCTest test bodies with a small adapter when CLT has no XCTest."""
from pathlib import Path
import os
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
# PDFKit/PencilKit tests need the XCTest host. Prefer the real suite whenever Xcode provides it.
native_runner = subprocess.run(["xcrun", "--find", "xctest"], capture_output=True, text=True)
if native_runner.returncode == 0:
    scratch = Path(tempfile.gettempdir()) / "percuscore-native-checks"
    raise SystemExit(subprocess.run(["swift", "test", "--scratch-path", str(scratch)], cwd=root).returncode)

shim = r'''
import Foundation
class XCTestCase {
    var teardown: [() throws -> Void] = []
    func addTeardownBlock(_ block: @escaping () throws -> Void) { teardown.append(block) }
    func cleanup() throws { for block in teardown.reversed() { try block() } }
}
func XCTFail(_ message: String = "Failed", file: StaticString = #file, line: UInt = #line) {
    fatalError("\(file):\(line): \(message)")
}
func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, file: StaticString = #file, line: UInt = #line) {
    do { if try !value() { XCTFail("Expected true", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, file: StaticString = #file, line: UInt = #line) {
    do { if try value() { XCTFail("Expected false", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                 file: StaticString = #file, line: UInt = #line) {
    do { let lhs = try a(), rhs = try b(); if lhs != rhs { XCTFail("\(lhs) != \(rhs)", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertEqual(_ a: Double, _ b: Double, accuracy: Double,
                    file: StaticString = #file, line: UInt = #line) {
    if !a.isFinite || !b.isFinite || abs(a - b) > accuracy {
        XCTFail("Values differ beyond tolerance", file: file, line: line)
    }
}
func XCTAssertNil<T>(_ a: @autoclosure () throws -> T?, file: StaticString = #file, line: UInt = #line) {
    do { if try a() != nil { XCTFail("Expected nil", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertNotNil<T>(_ a: @autoclosure () throws -> T?, file: StaticString = #file, line: UInt = #line) {
    do { if try a() == nil { XCTFail("Expected a value", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
struct UnwrapFailure: Error {}
func XCTUnwrap<T>(_ a: T?, file: StaticString = #file, line: UInt = #line) throws -> T {
    guard let a else { throw UnwrapFailure() }; return a
}
func XCTAssertThrowsError<T>(_ value: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line,
                            _ handler: (Error) -> Void = { _ in }) {
    do { _ = try value(); XCTFail("Expected an error", file: file, line: line) }
    catch { handler(error) }
}
'''
with tempfile.TemporaryDirectory(prefix="percuscore-checks-") as temp:
    work = Path(temp)
    (work / "Assertions.swift").write_text(shim)
    files = [str(p) for p in sorted((root / "Sources/PercuscoreCore").glob("*.swift"))]
    files.append(str(work / "Assertions.swift"))
    main = "import Foundation\n@main struct CoreChecks {\n@MainActor static func main() async {\n"
    count = 0
    for test_file in sorted((root / "Tests/PercuscoreCoreTests").glob("*.swift")):
        original = test_file.read_text()
        if "import AppKit" in original or "import PencilKit" in original:
            print(f"SKIPPED {test_file.name}: native PDF/Pencil tests require Xcode XCTest", flush=True)
            continue
        adapted = original.replace("import XCTest", "import Foundation").replace("@testable import PercuscoreCore", "")
        target = work / test_file.name
        target.write_text(adapted); files.append(str(target))
        suite = re.search(r"final class (\w+): XCTestCase", original).group(1)
        for method, asynchronous, throwing in re.findall(r"func (test\w+)\(\)( async)?( throws)?", original):
            main += f'do {{ let suite = {suite}(); {"try " if throwing else ""}{"await " if asynchronous else ""}suite.{method}(); try suite.cleanup(); print("PASS {suite}.{method}") }} catch {{ fatalError("Test threw: \\(error)") }}\n'
            count += 1
    main += f'print("ALL {count} CORE CHECKS PASSED")\n'
    main += "}\n}\n"
    (work / "Runner.swift").write_text(main); files.append(str(work / "Runner.swift"))
    cache = Path(tempfile.gettempdir()) / "percuscore-module-cache"
    cache.mkdir(exist_ok=True)
    environment = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(cache))
    binary = work / "core-checks"
    subprocess.run(["swiftc", "-module-cache-path", str(cache), *files, "-o", str(binary)], check=True, env=environment)
    subprocess.run([str(binary)], check=True, env=environment)
