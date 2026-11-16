import SwiftUI
import UIKit

@MainActor
final class DeviceAcceptanceCoordinator: ObservableObject {
    static let shared = DeviceAcceptanceCoordinator()
    let root: URL
    let currentBuild: AcceptanceBuild
    private let currentEnvironment: DeviceAcceptanceReport
    @Published private(set) var report: DeviceAcceptanceReport
    @Published private(set) var working = false
    @Published private(set) var progress = 0
    @Published private(set) var library: LibraryStore?
    @Published var error: String?
    private var blocked = false
    private var sessionURL: URL { root.appendingPathComponent("session.json") }
    var matchesCurrentBuild: Bool { report.build == currentBuild }
    var matchesCurrentEnvironment: Bool {
        report.deviceModel == currentEnvironment.deviceModel && report.systemVersion == currentEnvironment.systemVersion &&
        report.isSimulator == currentEnvironment.isSimulator
    }
    var canEdit: Bool { matchesCurrentBuild && matchesCurrentEnvironment && !blocked && !working }

    init(root: URL? = nil, build: AcceptanceBuild = .current) {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DeviceAcceptance")
        currentBuild = build
        currentEnvironment = Self.fresh(build)
        report = currentEnvironment
        if FileManager.default.fileExists(atPath: sessionURL.path) {
            do {
                let data = try LibraryDisk.readBounded(sessionURL, maximumBytes: 1024 * 1024)
                let restored = try JSONDecoder().decode(DeviceAcceptanceReport.self, from: data)
                guard restored.format == "percuscore-device-stability", restored.formatVersion == 1,
                      restored.checks.map(\.id) == report.checks.map(\.id) else { throw LibraryError.unsupportedVersion }
                report = restored
                if report.rehearsalStartedAt != nil {
                    var interrupted = report; interrupted.interruptRehearsal()
                    try persist(interrupted); report = interrupted
                }
            } catch { blocked = true; self.error = "Saved acceptance record could not be opened. Start a new run to preserve it separately. \(error.localizedDescription)" }
        } else {
            do { try persist(report) } catch { blocked = true; self.error = error.localizedDescription }
        }
    }
    private static func fresh(_ build: AcceptanceBuild) -> DeviceAcceptanceReport {
        var system = utsname(); uname(&system)
        let machineSize = MemoryLayout.size(ofValue: system.machine)
        let model = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: machineSize) { String(cString: $0) }
        }
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        return DeviceAcceptanceReport(build: build, deviceModel: model,
                                      systemVersion: UIDevice.current.systemVersion, isSimulator: simulator)
    }
    private func persist(_ candidate: DeviceAcceptanceReport) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(candidate)
        guard data.count <= 1024 * 1024 else { throw LibraryError.corruptIndex }
        try data.write(to: sessionURL, options: .atomic)
    }
    func update(_ edit: (inout DeviceAcceptanceReport) -> Void) {
        guard canEdit else { return }
        var candidate = report; edit(&candidate)
        do { try persist(candidate); report = candidate }
        catch { self.error = "Could not save acceptance result. Your previous record is preserved. \(error.localizedDescription)" }
    }
    @discardableResult
    func newRun() -> Bool {
        guard !working else { return false }
        do {
            let archives = root.appendingPathComponent("reports")
            try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: sessionURL.path) {
                let name = blocked ? "unreadable-\(UUID().uuidString)" : report.id.uuidString
                var target = archives.appendingPathComponent(name + ".json")
                // An earlier archive may have succeeded before session replacement failed.
                // Preserve both that archive and any later observations when retrying.
                if FileManager.default.fileExists(atPath: target.path) {
                    target = archives.appendingPathComponent(name + "-" + UUID().uuidString + ".json")
                }
                try FileManager.default.copyItem(at: sessionURL, to: target)
            }
            let candidate = Self.fresh(currentBuild)
            try persist(candidate); report = candidate; blocked = false; error = nil; library = nil
            return true
        } catch { self.error = "Could not preserve the previous record or start a new run. \(error.localizedDescription)"; return false }
    }
    func prepareLibrary(rebuild: Bool = false) {
        guard canEdit else { return }
        working = true; progress = 0; error = nil
        let destination = root.appendingPathComponent("library-v1")
        let staging = root.appendingPathComponent("preparing-\(UUID().uuidString)")
        Task {
            defer { working = false }
            do {
                let manifest = try await Task.detached(priority: .userInitiated) {
                    if !rebuild, FileManager.default.fileExists(atPath: destination.appendingPathComponent("manifest.json").path) {
                        return try AcceptanceFixtures.verify(at: destination)
                    }
                    defer { try? FileManager.default.removeItem(at: staging) }
                    let built = try AcceptanceFixtures.build(at: staging) { count in
                        Task { @MainActor in self.progress = count }
                    }
                    let backup = destination.deletingLastPathComponent().appendingPathComponent("replaced-\(UUID().uuidString)")
                    let previous = FileManager.default.fileExists(atPath: destination.path)
                    if previous { try FileManager.default.moveItem(at: destination, to: backup) }
                    do { try FileManager.default.moveItem(at: staging, to: destination) }
                    catch {
                        if previous { try? FileManager.default.moveItem(at: backup, to: destination) }
                        throw error
                    }
                    if previous { try? FileManager.default.removeItem(at: backup) }
                    return built
                }.value
                guard manifest.scanPages == 120, manifest.scanDPI == 300 else { throw LibraryError.invalidPDF }
                let store = LibraryStore(root: destination, isAcceptanceLibrary: true)
                guard store.isReady else { throw LibraryError.corruptIndex }
                let hash = try AcceptanceFixtures.sha256(destination.appendingPathComponent("manifest.json"))
                if let previous = report.fixtureManifestSHA256, previous != hash { throw LibraryError.corruptIndex }
                var candidate = report; candidate.fixtureManifestSHA256 = hash
                try persist(candidate); report = candidate; library = store
                ReaderDiagnostics.shared.enabled = true
            } catch { self.error = "Could not prepare the test library. Existing library files were not imported or moved. \(error.localizedDescription)" }
        }
    }
    func export(diagnostics: ReaderDiagnostics) throws -> [URL] {
        try diagnostics.log.flush()
        let directory = root.appendingPathComponent("exports/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let json = directory.appendingPathComponent("report.json"), markdown = directory.appendingPathComponent("report.md")
            let log = directory.appendingPathComponent("diagnostics.json")
            try encoder.encode(report).write(to: json, options: .atomic)
            try Data(report.markdown.utf8).write(to: markdown, options: .atomic)
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(diagnostics.events()).write(to: log, options: .atomic)
            return [json, markdown, log]
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
}
