import Foundation

public struct AcceptanceBuild: Codable, Equatable, Sendable {
    public let version: String
    public let build: String
    public let commit: String
    public let sourceState: String
    public init(version: String, build: String, commit: String, sourceState: String) {
        self.version = String(version.prefix(64)); self.build = String(build.prefix(64))
        self.commit = String(commit.prefix(64)); self.sourceState = String(sourceState.prefix(16))
    }
    public var traceable: Bool {
        sourceState == "clean" && (commit.count == 40 || commit.count == 64) &&
        commit.allSatisfy { $0.isHexDigit } && !version.isEmpty && version != "Unknown" && !build.isEmpty && build != "Unknown"
    }
}

public enum AcceptanceOutcome: String, Codable, CaseIterable, Sendable {
    case notRun = "not_run", passed, failed
}
public enum AcceptanceStatus: String, Codable, Sendable { case incomplete, passed, failed }
public struct AcceptanceCheck: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public var outcome: AcceptanceOutcome = .notRun
    public var notes = ""
    public var everFailed = false
    public var recordedAt: Date?
}

public struct DeviceAcceptanceReport: Codable, Identifiable, Sendable {
    public let format: String
    public let formatVersion: Int
    public let id: UUID
    public let createdAt: Date
    public let build: AcceptanceBuild
    public let deviceModel: String
    public let systemVersion: String
    public let isSimulator: Bool
    public var operatorName = ""
    public var pencilModel = ""
    public var fixtureManifestSHA256: String?
    public private(set) var checks: [AcceptanceCheck]
    public private(set) var rehearsalStartedAt: Date?
    public var rehearsalDurationSeconds: Double = 0
    public private(set) var rehearsalInterrupted = false
    public var rehearsalOutcome: AcceptanceOutcome = .notRun {
        didSet { if rehearsalOutcome == .failed { rehearsalEverFailed = true } }
    }
    public var rehearsalNotes = ""
    public private(set) var rehearsalEverFailed = false
    public var issueSteps = ""
    private static let supplemental = [
        ("palm", "Palm contact while writing"),
        ("zoom", "Two-finger zoom and pan, then write"),
        ("switch", "Rapid mode and page switching"),
        ("background", "Background while annotating, then return"),
        ("lock", "Lock screen while annotating, unlock and continue"),
        ("relaunch", "Save, end process, reopen: page and ink preserved"),
        ("isolation", "Move between pages and works: no misplaced ink"),
        ("rotated", "Rotated, cropped and marked pages remain aligned"),
        ("large-scan", "Large scanned score: open, turn and annotate"),
        ("setlist", "Cross-work setlist navigation and resume")
    ]
    private static var inputChecks: [AcceptanceCheck] {
        (1...30).map { AcceptanceCheck(id: String(format: "input-%02d", $0), title: "Input chain \($0) / 30") }
    }
    private static var requiredIDs: Set<String> { Set(inputChecks.map(\.id) + supplemental.map(\.0)) }

    public init(build: AcceptanceBuild, deviceModel: String, systemVersion: String, isSimulator: Bool) {
        format = "percuscore-device-stability"; formatVersion = 1
        id = UUID(); createdAt = Date(); self.build = build
        self.deviceModel = deviceModel; self.systemVersion = systemVersion; self.isSimulator = isSimulator
        checks = Self.inputChecks + Self.supplemental.map { AcceptanceCheck(id: $0.0, title: $0.1) }
    }
    public mutating func record(id: String, outcome: AcceptanceOutcome, notes: String) {
        guard let i = checks.firstIndex(where: { $0.id == id }) else { return }
        checks[i].outcome = outcome; checks[i].notes = String(notes.prefix(4000))
        checks[i].everFailed = checks[i].everFailed || outcome == .failed
        checks[i].recordedAt = Date()
    }
    public mutating func startRehearsal(at date: Date = Date()) {
        rehearsalStartedAt = date; rehearsalDurationSeconds = 0
        rehearsalInterrupted = false; rehearsalOutcome = .notRun
    }
    public mutating func stopRehearsal(at date: Date = Date()) {
        guard let start = rehearsalStartedAt else { return }
        rehearsalDurationSeconds = max(0, date.timeIntervalSince(start))
        rehearsalStartedAt = nil
    }
    public mutating func interruptRehearsal() {
        guard rehearsalStartedAt != nil else { return }
        rehearsalStartedAt = nil; rehearsalInterrupted = true; rehearsalOutcome = .notRun
    }
    public var status: AcceptanceStatus {
        if checks.contains(where: { $0.everFailed || $0.outcome == .failed }) || rehearsalEverFailed || rehearsalOutcome == .failed { return .failed }
        let identity = fixtureManifestSHA256 ?? ""
        guard format == "percuscore-device-stability", formatVersion == 1,
              build.traceable, !isSimulator, !deviceModel.isEmpty, !systemVersion.isEmpty,
              !operatorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !pencilModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              identity.count == 64, identity.allSatisfy({ $0.isHexDigit }),
              checks.count == Self.requiredIDs.count, Set(checks.map(\.id)) == Self.requiredIDs,
              checks.allSatisfy({ $0.outcome == .passed }),
              rehearsalStartedAt == nil, !rehearsalInterrupted, rehearsalDurationSeconds.isFinite,
              rehearsalDurationSeconds >= 1800, rehearsalOutcome == .passed else { return .incomplete }
        return .passed
    }
    public var markdown: String {
        func safe(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>") }
        var lines = ["# Percuscore device stability report", "", "Result: **\(status.rawValue)** (operator-reported observations)",
            "", "Run: \(id.uuidString)", "Created: \(ISO8601DateFormatter().string(from: createdAt))",
            "Device: \(safe(deviceModel)); OS \(safe(systemVersion)); Simulator: \(isSimulator)",
            "App: \(safe(build.version)) (\(safe(build.build)))", "Commit: \(build.commit); state: \(build.sourceState)",
            "Operator: \(safe(operatorName)); Pencil: \(safe(pencilModel))", "Fixture manifest SHA-256: \(fixtureManifestSHA256 ?? "not prepared")",
            "", "Input chain: first Pencil stroke → continuous writing → Done → tap saved ink → turn → return → annotate again.",
            "", "| Check | Result | Ever failed | Notes |", "|---|---|---|---|"]
        lines += checks.map { "| \(safe($0.title)) | \($0.outcome.rawValue) | \($0.everFailed) | \(safe($0.notes)) |" }
        lines += ["", "Rehearsal: \(rehearsalDurationSeconds) seconds; \(rehearsalOutcome.rawValue); interrupted: \(rehearsalInterrupted)",
                  "Rehearsal notes: \(rehearsalNotes)", "", "## Reproduction steps", issueSteps,
                  "", "Physical Pencil and rehearsal quality are manual observations. Simulator runs cannot pass device acceptance.",
                  "Diagnostics contain only typed operation/state/page/timing metadata; no PDF or ink content."]
        return lines.joined(separator: "\n") + "\n"
    }
}
