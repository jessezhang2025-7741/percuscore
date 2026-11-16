// Compiled ONLY into the disposable benchmark host, never the shipping target.
import SwiftUI
import QuartzCore
import Darwin

@MainActor final class PerformanceProbe: NSObject, ObservableObject {
    static let shared = PerformanceProbe()
    @Published var done = false
    private weak var model: ReaderModel?
    private var openStart = 0.0
    private var modelReady = 0.0
    private var tiles: [ObjectIdentifier: Double] = [:]
    private var frames: [Double] = []
    private var previousFrame = 0.0
    private var link: CADisplayLink?
    private var memoryTimer: Timer?
    private var peak: UInt64 = 0
    private var before: UInt64 = 0

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
    func beginOpen() {
        openStart = ProcessInfo.processInfo.systemUptime; before = Self.footprint(); peak = before
        link = CADisplayLink(target: self, selector: #selector(frame(_:))); link?.add(to: .main, forMode: .common)
        memoryTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self { self.peak = max(self.peak, Self.footprint()) } }
        }
    }
    @objc private func frame(_ link: CADisplayLink) {
        if previousFrame > 0 { frames.append((link.timestamp - previousFrame) * 1000) }
        previousFrame = link.timestamp
    }
    func opened(_ model: ReaderModel) {
        guard openStart > 0, self.model == nil else { return }
        self.model = model; modelReady = ProcessInfo.processInfo.systemUptime
        Task { await run() }
    }
    nonisolated static func tile(_ page: PDFPage) {
        let id = ObjectIdentifier(page), time = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in if shared.tiles[id] == nil { shared.tiles[id] = time } }
    }
    private func painted(_ id: ObjectIdentifier, since start: Double) async -> Double? {
        for _ in 0..<800 {
            if let time = tiles[id], time >= start { return time }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }
    private func run() async {
        var reader = model
        guard let page = reader?.page else { return }
        let first = await painted(ObjectIdentifier(page), since: openStart)
        let openMemory = Self.footprint()
        // Allow presentation animation to settle before measuring page turns.
        try? await Task.sleep(nanoseconds: 600_000_000)
        var turns: [[String: Any]] = []
        for forward in [true, false] {
            for _ in 0..<50 {
                let start = ProcessInfo.processInfo.systemUptime
                reader?.turn(forward: forward)
                let state = ProcessInfo.processInfo.systemUptime
                guard let page = reader?.page else { break }
                tiles.removeValue(forKey: ObjectIdentifier(page))
                let tile = await painted(ObjectIdentifier(page), since: start)
                turns.append(["page": reader!.pageIndex, "forward": forward,
                    "state_ms": (state-start)*1000, "tile_ms": tile.map { ($0-start)*1000 } ?? -1])
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let idle = Self.footprint()
        link?.invalidate(); link = nil; memoryTimer?.invalidate(); memoryTimer = nil
        reader?.flushDraft()
        NotificationCenter.default.post(name: .init("BenchmarkClose"), object: nil)
        reader = nil
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let result: [String: Any] = ["fixture_sha256": "FIXTURE_ID", "model_ms": (modelReady-openStart)*1000,
            "open_ms": first.map { ($0-openStart)*1000 } ?? -1, "turns": turns, "frame_ms": frames,
            "before_bytes": before, "open_bytes": openMemory, "peak_bytes": peak,
            "idle_bytes": idle, "close_bytes": Self.footprint()]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("metrics-" + (ProcessInfo.processInfo.environment["PERFORMANCE_RUNSET"] ?? "default"))
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try! data.write(to: documents.appendingPathComponent("metrics-" + (ProcessInfo.processInfo.environment["PERFORMANCE_RUNSET"] ?? "default")).appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
        done = true
    }
}

struct BenchmarkBanner: View {
    @ObservedObject var probe = PerformanceProbe.shared
    var body: some View { if probe.done { Text("Performance complete").accessibilityIdentifier("Performance complete") } }
}
