import Foundation
import SwiftUI
import UIKit

extension AcceptanceBuild {
    static let current: AcceptanceBuild = {
        let bundle = Bundle.main
        let info = bundle.url(forResource: "BuildInfo", withExtension: "plist")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        return AcceptanceBuild(version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown",
                               build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown",
                               commit: info["commit"] as? String ?? "", sourceState: info["source_state"] as? String ?? "unavailable")
    }()
}

@MainActor
final class ReaderDiagnostics: ObservableObject {
    static let shared = ReaderDiagnostics()
    let log: BoundedDiagnosticLog
    private let config: URL
    private let processID = UUID()
    @Published var enabled: Bool {
        didSet {
            do {
                try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(enabled).write(to: config, options: .atomic)
            } catch { storageError = "Could not save diagnostics preference: \(error.localizedDescription)" }
        }
    }
    @Published private(set) var storageError: String?
    init(root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ReaderDiagnostics")
        config = base.appendingPathComponent("enabled.json")
        if let data = try? LibraryDisk.readBounded(config, maximumBytes: 1024), let value = try? JSONDecoder().decode(Bool.self, from: data) { enabled = value }
        else { enabled = false }
        log = BoundedDiagnosticLog(url: base.appendingPathComponent("events.json"))
    }
    func record(_ kind: ReaderDiagnosticEvent.Kind, state: ReaderDiagnosticEvent.State,
                page: Int? = nil, item: Int? = nil, durationMS: Double? = nil) {
        guard enabled else { return }
        var event = ReaderDiagnosticEvent(kind: kind, state: state, page: page, item: item, durationMS: durationMS)
        event.build = .current; event.processID = processID
        log.record(event)
    }
    func flush() {
        guard enabled else { return }
        do { try log.flush() }
        catch { storageError = "Diagnostic log could not be saved: \(error.localizedDescription)" }
    }
    func events() throws -> [ReaderDiagnosticEvent] { try log.snapshot() }
    func clear() {
        do { try log.clear(); storageError = nil }
        catch { storageError = error.localizedDescription }
    }
}
