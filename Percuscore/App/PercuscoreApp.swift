import SwiftUI

@main
struct PercuscoreApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var diagnostics = ReaderDiagnostics.shared
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .tint(Theme.accent)
                .onOpenURL { url in Task { _ = await library.importPDFs([url]) } }
                .onChange(of: scenePhase) { _, phase in
                    if let state = ReaderDiagnosticEvent.State(rawValue: String(describing: phase)) { diagnostics.record(.lifecycle, state: state) }
                    if phase == .background { diagnostics.flush() }
                }
        }
    }
}
