from pathlib import Path
import shutil
import hashlib

def fixture_identity(fixture):
    digest = hashlib.sha256()
    with Path(fixture).open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''): digest.update(chunk)
    return digest.hexdigest()

def configure(work, fixture, glass):
    root = Path(__file__).resolve().parents[1]
    identity = fixture_identity(fixture)
    shutil.copy2(fixture, work / 'Percuscore/Resources/large-scan.pdf')
    app = r'''import SwiftUI
import PDFKit
import PencilKit
@main @MainActor struct PercuscoreApp: App {
    @StateObject private var store: LibraryStore
    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let library = LibraryStore(root: documents.appendingPathComponent("BenchmarkLibrary-FIXTURE_ID"))
        let score = Score(id: UUID(uuidString: "73BAE18D-387F-452B-8FF8-258D496F0309")!, title: "Large scanned score", pageCount: 120)
        let destination = library.disk!.pdfURL(for: score.id)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try! FileManager.default.copyItem(at: Bundle.main.url(forResource: "large-scan", withExtension: "pdf")!, to: destination)
        }
        _ = library.update { $0.scores = [score]; $0.settings = ReaderSettings() }
        _store = StateObject(wrappedValue: library)
    }
    var body: some Scene {
        WindowGroup { LibraryView().environmentObject(store).overlay(alignment: .bottom) { BenchmarkBanner() }
            .tint(Theme.accent).preferredColorScheme(.light) }
    }
}
'''
    app = app.replace("FIXTURE_ID", identity)
    if (work / 'Percuscore/App/ReaderDiagnosticsService.swift').exists():
        app = app.replace('    init() {', '    init() {\n        ReaderDiagnostics.shared.enabled = false', 1)
    (work / 'Percuscore/App/PercuscoreApp.swift').write_text(app + (root / 'scripts/large_pdf_benchmark_host.swift').read_text().replace("FIXTURE_ID", identity))
    path = work / 'Percuscore/Reader/ReaderModel.swift'
    source = path.read_text().replace('        loadCurrentPage()\n', '        loadCurrentPage()\n        PerformanceProbe.shared.opened(self)\n', 1)
    path.write_text(source)
    path = work / 'Percuscore/Library/LibraryView.swift'
    source = path.read_text().replace('    private func open(_ score: Score, bookmark: ScoreBookmark? = nil) {',
        '    private func open(_ score: Score, bookmark: ScoreBookmark? = nil) {\n        PerformanceProbe.shared.beginOpen()')
    path.write_text(source)
    path = work / 'Percuscore/Reader/PageRendering.swift'
    source = path.read_text().replace('        PageRendering.drawPDF(page, in: context, rect: bounds)',
        '        PageRendering.drawPDF(page, in: context, rect: bounds)\n        PerformanceProbe.tile(page)')
    path.write_text(source)
    path = work / 'Percuscore/Reader/ReaderView.swift'
    source = path.read_text().replace('    var body: some View {',
        '    var body: some View { benchmarkBody.onReceive(NotificationCenter.default.publisher(for: .init("BenchmarkClose"))) { _ in dismiss() } }\n    private var benchmarkBody: some View {', 1)
    path.write_text(source)
    if glass == 'off':
        path = work / 'Percuscore/App/Theme.swift'
        source = path.read_text().replace('content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)',
            'content.background(Theme.surface, in: shape)')
        source = source.replace('.buttonStyle(.glassProminent)', '.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)')
        source = source.replace('.buttonStyle(.glass)', '.buttonStyle(.bordered).buttonBorderShape(.capsule)')
        path.write_text(source)
        path = work / 'Percuscore/Reader/ScoreSurface.swift'
        source = path.read_text().replace('badge.effect = glass', 'badge.effect = nil')
        path.write_text(source)

def add_resource(objects, app, uid):
    ref, build = uid('large-scan'), uid('large-scan-build')
    objects[ref] = dict(isa='PBXFileReference', lastKnownFileType='image.pdf', path='Percuscore/Resources/large-scan.pdf', sourceTree='SOURCE_ROOT')
    objects[build] = dict(isa='PBXBuildFile', fileRef=ref)
    phase = next(objects[p] for p in app['buildPhases'] if objects[p]['isa'] == 'PBXResourcesBuildPhase')
    phase['files'].append(build)
