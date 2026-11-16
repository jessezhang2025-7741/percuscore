import XCTest
@testable import PercuscoreCore

final class DeviceAcceptanceTests: XCTestCase {
    private var build: AcceptanceBuild {
        AcceptanceBuild(version: "0.1.0", build: "1", commit: String(repeating: "a", count: 40), sourceState: "clean")
    }
    private func report(simulator: Bool = false) -> DeviceAcceptanceReport {
        DeviceAcceptanceReport(build: build, deviceModel: "iPad13,16", systemVersion: "26.5", isSimulator: simulator)
    }
    private func completed(simulator: Bool = false) -> DeviceAcceptanceReport {
        var r = report(simulator: simulator)
        r.operatorName = "Tester"; r.pencilModel = "Apple Pencil 2"; r.fixtureManifestSHA256 = String(repeating: "b", count: 64)
        for id in r.checks.map(\.id) { r.record(id: id, outcome: .passed, notes: "Observed on device") }
        let start = Date(timeIntervalSince1970: 1000)
        r.startRehearsal(at: start); r.stopRehearsal(at: start.addingTimeInterval(1800))
        r.rehearsalOutcome = .passed
        return r
    }
    func testNewReportHasThirtySeparateUnexecutedRepetitionsAndRequiredChecks() {
        let r = report()
        XCTAssertEqual(r.checks.filter { $0.id.hasPrefix("input-") }.count, 30)
        XCTAssertTrue(r.checks.allSatisfy { $0.outcome == .notRun })
        XCTAssertEqual(r.status, .incomplete)
    }
    func testOnlyCompletePhysicalEvidenceAndLongEnoughRehearsalPass() {
        XCTAssertEqual(completed().status, .passed)
        XCTAssertEqual(completed(simulator: true).status, .incomplete)
        var r = completed(); r.rehearsalDurationSeconds = 1799
        XCTAssertEqual(r.status, .incomplete)
        r.rehearsalDurationSeconds = 1800; r.operatorName = " "
        XCTAssertEqual(r.status, .incomplete)
    }
    func testFailureCannotBeErasedByChangingAnOutcomeToPassed() {
        var r = completed()
        r.record(id: "input-01", outcome: .failed, notes: "First stroke lost")
        r.record(id: "input-01", outcome: .passed, notes: "Retry passed")
        XCTAssertEqual(r.status, .failed)
        XCTAssertTrue(r.checks.first { $0.id == "input-01" }!.everFailed)
    }
    func testReportRoundTripKeepsExactBuildNotesAndOutcomes() throws {
        let r = completed()
        let data = try JSONEncoder().encode(r)
        let restored = try JSONDecoder().decode(DeviceAcceptanceReport.self, from: data)
        XCTAssertEqual(restored.build, build)
        XCTAssertEqual(restored.id, r.id)
        XCTAssertEqual(restored.status, .passed)
        XCTAssertTrue(restored.markdown.contains(build.commit))
        XCTAssertTrue(restored.markdown.contains("Observed on device"))
    }
    func testKilledRehearsalRemainsIncompleteAndDoesNotCountClosedTime() {
        var r = completed()
        r.startRehearsal(at: Date(timeIntervalSince1970: 100))
        r.interruptRehearsal()
        XCTAssertTrue(r.rehearsalInterrupted)
        XCTAssertNil(r.rehearsalStartedAt)
        XCTAssertEqual(r.status, .incomplete)
    }
    func testMissingOrDirtySourceAndFixtureCannotPass() {
        var r = completed(); r.fixtureManifestSHA256 = nil
        XCTAssertEqual(r.status, .incomplete)
        r = completed()
        r = DeviceAcceptanceReport(build: AcceptanceBuild(version: "1", build: "2", commit: "", sourceState: "modified"), deviceModel: r.deviceModel, systemVersion: r.systemVersion, isSimulator: false)
        XCTAssertEqual(r.status, .incomplete)
    }
    func testDuplicatedPersistedCheckCannotReplaceAMissingRequiredObservation() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(completed())) as! [String: Any]
        var checks = json["checks"] as! [[String: Any]]
        checks[1] = checks[0]; json["checks"] = checks
        let restored = try JSONDecoder().decode(DeviceAcceptanceReport.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.status, .incomplete)
    }
    func testRehearsalFailureIsRetainedWhenResultIsCorrected() {
        var r = completed(); r.rehearsalOutcome = .failed; r.rehearsalOutcome = .passed
        XCTAssertEqual(r.status, .failed)
    }
}
