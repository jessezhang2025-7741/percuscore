#!/usr/bin/env python3
"""Check reader controls and page navigation in an isolated fixture; preserve the shipping app."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

if len(sys.argv) < 2:
    sys.exit("Usage: run_toolbar_ui_checks.py <SIMULATOR-UUID> [xcodebuild arguments...]")

HARNESS_ROOT = Path(__file__).resolve().parents[1]
ROOT = Path(os.environ.get("PERFORMANCE_SOURCE_ROOT", str(HARNESS_ROOT)))
WORK = Path(os.environ.get("PERFORMANCE_WORK", str(Path(tempfile.gettempdir()) / "Percuscore-toolbar-ui-tests")))
WORK.mkdir(parents=True, exist_ok=True)
for directory in ["Percuscore", "Sources", "Tests/PercuscoreUITests", "Percuscore.xcodeproj", "scripts"]:
    # Replace this runner's disposable source copies, including removed tests.
    if (WORK / directory).exists():
        shutil.rmtree(WORK / directory)
    source_root = HARNESS_ROOT if os.environ.get("LARGE_PDF_BENCHMARK") == "1" and directory == "Tests/PercuscoreUITests" else ROOT
    shutil.copytree(source_root / directory, WORK / directory, dirs_exist_ok=True)

# Configure the disposable test host only. Shipping app/signing stay untouched.
if os.environ.get("LARGE_PDF_BENCHMARK") == "1":
    from large_pdf_benchmark_support import configure
    configure(WORK, os.environ["PERFORMANCE_FIXTURE"], os.environ["PERFORMANCE_GLASS"])
else:
    reader = WORK / "Percuscore/Reader/ReaderView.swift"
    source = reader.read_text()
    original = "_model = StateObject(wrappedValue: ReaderModel(store: store, session: session))"
    assert original in source
    source = source.replace(original, "_model = StateObject(wrappedValue: ToolbarFixture.makeModel(store: store, session: session))", 1)
    # Only the disposable host exposes this opt-in control. Long gesture tests
    # exercise scrubbing independently of the separately tested idle deadline.
    hide_guard = "guard shouldAutoHideControls else { return }"
    assert hide_guard in source
    source = source.replace(hide_guard,
        'guard shouldAutoHideControls, ProcessInfo.processInfo.environment["TOOLBAR_KEEP_CONTROLS_VISIBLE"] != "1" else { return }', 1)
    # UI automation isolates the production toolbar from PencilKit's live canvas.
    start = source.index("    var body: some View {")
    end = source.index("    private func updateIdleTimer()", start)
    shipping_body = source[start:end].replace("    var body: some View {", "    private var fullReaderBody: some View {", 1)
    source = source[:start] + r'''    var body: some View {
            if ProcessInfo.processInfo.environment["TOOLBAR_REAL_BODY"] == "1" {
                fullReaderBody.overlay(alignment: .bottomLeading) {
                    if ProcessInfo.processInfo.environment["VALIDATION_RELAUNCH_ID"] != nil {
                        VStack {
                            Text("Ink: \(ToolbarFixture.persistedStrokes(store, model)) saved, \(model.canvas.drawing.strokes.count) loaded")
                            Text("Saved page: \(store.index.scores.first(where: { $0.id == model.scoreID })?.lastPageNumber ?? 0)")
                        }.font(.caption).allowsHitTesting(false)
                    }
                }
            }
            else {
            VStack(spacing: 8) {
                if model.mode == .annotating { annotationToolbar }
                else { header(compact: true) }
                saveStatusBadge
                if model.mode == .cropping { cropInstruction }
                if ProcessInfo.processInfo.environment["TOOLBAR_SURFACE"] == "1" {
                    ScoreSurface(model: model, displayOptions: { displayOptions = true })
                        .frame(maxHeight: .infinity)
                } else if let page = model.page {
                    Image(uiImage: page.thumbnail(of: CGSize(width: 700, height: 1000), for: .mediaBox))
                        .resizable().scaledToFit().accessibilityHidden(true)
                }
                Spacer(minLength: 0)
                if model.mode == .cropping { cropControls } else { pageControls }
            }.background(.white)
                .onChange(of: model.session.position.page) { _, page in if !seeking { seekValue = Double(page) } }
                .sheet(isPresented: $pageNavigator) { PageNavigatorPanel(model: model, store: store) }
                .sheet(isPresented: $cropAdjustments) { cropAdjustmentsPanel }
                .sheet(isPresented: $bookmarks) { BookmarkPanel(model: model, store: store) }
                .sheet(isPresented: $displayOptions) { SettingsView(allowsBackup: false).environmentObject(store) }

            }
        }

    ''' + shipping_body + source[end:]
    reader.write_text(source)
    (WORK / "Percuscore/App/PercuscoreApp.swift").write_text(r'''import SwiftUI
    import PencilKit
    import PDFKit

    @main @MainActor
    struct PercuscoreApp: App {
        @StateObject private var store: LibraryStore
        private let session: ReadingSession
        private let width: CGFloat
        private let largeText: Bool
        @State private var acceptance: DeviceAcceptanceCoordinator?
        init() {
            if ProcessInfo.processInfo.environment["TOOLBAR_ACCEPTANCE"] == "1" {
                let runID = ProcessInfo.processInfo.environment["VALIDATION_ACCEPTANCE_ID"].flatMap(UUID.init(uuidString:)) ?? UUID()
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                _acceptance = State(initialValue: DeviceAcceptanceCoordinator(root: documents.appendingPathComponent("Validation-acceptance-" + runID.uuidString)))
            } else {
                _acceptance = State(initialValue: nil)
                ReaderDiagnostics.shared.enabled = false
            }
            if let runID = ProcessInfo.processInfo.environment["VALIDATION_RELAUNCH_ID"], UUID(uuidString: runID) != nil {
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let library = LibraryStore(root: documents.appendingPathComponent("Validation-relaunch-" + runID))
                if library.index.scores.isEmpty {
                    let score = Score(title: "Live relaunch practice", pageCount: 4)
                    try! SampleScore.write(to: library.disk!.pdfURL(for: score.id))
                    _ = library.update { $0.scores = [score]; $0.settings = ReaderSettings(); $0.settings.preventFingerDrawing = false }
                }
                let score = library.index.scores[0]
                _store = StateObject(wrappedValue: library)
                session = ReadingSession(queue: [.init(scoreID: score.id, title: score.title, startPage: 0, endPage: 3)], page: score.lastPage)!
                width = 834; largeText = false
                return
            }
            // A fresh root also isolates setlist/bookmark references across fixtures.
            // The dedicated relaunch branch above deliberately keeps its own root.
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let library = LibraryStore(root: documents.appendingPathComponent("Validation-fixture-" + UUID().uuidString))
            if ProcessInfo.processInfo.environment["TOOLBAR_BACKUP_EXPORTED"] == "1" {
                try! library.completeBackupExport(saved: true, at: Date(timeIntervalSince1970: 1_700_000_000))
            }
            let longScore = ProcessInfo.processInfo.environment["TOOLBAR_LONG_SCORE"] == "1"
            let accessibility = ProcessInfo.processInfo.environment["TOOLBAR_ACCESSIBILITY"] == "1"
            var score = Score(title: accessibility ? "Concerto for percussion and orchestra — an extended rehearsal score" : "Portrait markup practice", pageCount: longScore ? 120 : 4)
            if accessibility { score.composer = "A composer with a long name"; score.part = "Percussion and timpani"; score.tags = ["Rehearsal", "Orchestra"] }
            score.bookmarks = [.init(title: "Cue B", startPage: 1), .init(title: "Finale", startPage: 2, endPage: 3)]
            if longScore {
                let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800))
                try! renderer.writePDF(to: library.disk!.pdfURL(for: score.id)) { context in
                    for page in 1...120 {
                        context.beginPage()
                        "Practice score · Page \(page)".draw(at: CGPoint(x: 60, y: 60),
                            withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.black])
                    }
                }
            } else { try! SampleScore.write(to: library.disk!.pdfURL(for: score.id)) }
            let pdf = PDFDocument(url: library.disk!.pdfURL(for: score.id))!
            // Write real persisted outlines: PDFKit's outline-only rewrite can
            // omit the new tree on current Simulator runtimes.
            let pageBounds = pdf.page(at: 0)!.bounds(for: .mediaBox)
            let outlinedData = UIGraphicsPDFRenderer(bounds: pageBounds).pdfData { context in
                for number in 0..<pdf.pageCount {
                    context.beginPage()
                    let cg = context.cgContext
                    cg.saveGState()
                    cg.translateBy(x: 0, y: pageBounds.height); cg.scaleBy(x: 1, y: -1)
                    cg.drawPDFPage(pdf.page(at: number)!.pageRef!)
                    cg.restoreGState()
                }
                CGPDFContextSetOutline(context.cgContext, [kCGPDFOutlineChildren as String: [
                    [kCGPDFOutlineTitle as String: "I. Allegro", kCGPDFOutlineDestination as String: 1],
                    [kCGPDFOutlineTitle as String: "II. Adagio", kCGPDFOutlineDestination as String: 3]
                ]] as CFDictionary)
            }
            try! outlinedData.write(to: library.disk!.pdfURL(for: score.id))
            precondition(PDFDocument(url: library.disk!.pdfURL(for: score.id))?.outlineRoot?.numberOfChildren == 2,
                         "UI fixture must contain persisted PDF sections")
            precondition(library.update {
                $0.scores = [score]; $0.settings = ReaderSettings()
                if ProcessInfo.processInfo.environment["TOOLBAR_FINGER_INPUT"] == "1" {
                    $0.settings.preventFingerDrawing = false
                }
            }, "Could not initialize isolated UI fixture")
            if accessibility {
                precondition(library.update {
                    $0.settings.halfPageTurns = true
                    var setlist = ScoreSetlist(title: "Autumn performance")
                    setlist.entries = [SetlistEntry(scoreID: score.id)]
                    $0.setlists = [setlist]
                }, "Could not initialize accessibility fixture")
            }
            if ProcessInfo.processInfo.environment["TOOLBAR_BACKUP_VERIFIED"] == "1" {
                let disk = library.disk!, id = UUID()
                let archive = disk.root.appendingPathComponent("ui-verification.percuscorebackup")
                try! LibraryBackup.export(index: library.index, disk: disk, to: archive)
                let result = try! LibraryBackup.verify(from: archive, at: disk.root.appendingPathComponent(".backup-verifications/" + id.uuidString + "/restored"))
                var records = BackupRecords()
                records.verification = BackupVerificationService.evidence(result, id: id, records: records)
                try! disk.saveBackupRecords(records); library.reload()
            }
            _store = StateObject(wrappedValue: library)
            session = ReadingSession(queue: [.init(scoreID: score.id, title: score.title, startPage: 0, endPage: score.pageCount - 1)],
                page: longScore ? 88 : 0)!
            width = CGFloat(Double(ProcessInfo.processInfo.environment["TOOLBAR_WIDTH"] ?? "834") ?? 834)
            largeText = ProcessInfo.processInfo.environment["TOOLBAR_LARGE_TEXT"] == "1"
        }
        var body: some Scene {
            WindowGroup {
                Group {
                    if let acceptance {
                        NavigationStack { DeviceAcceptanceView(coordinator: acceptance) }
                    } else if ProcessInfo.processInfo.environment["TOOLBAR_LIBRARY"] == "1" {
                        LibraryView().environmentObject(store)
                    } else if ProcessInfo.processInfo.environment["TOOLBAR_SETLIST"] == "1" {
                        AddToSetlistView(setlistID: store.index.setlists[0].id).environmentObject(store)
                    } else if ProcessInfo.processInfo.environment["TOOLBAR_PRESET"] == "1" {
                        PresetEditor(store: store, index: 0)
                    } else if ProcessInfo.processInfo.environment["TOOLBAR_BACKUP"] == "1" {
                        NavigationStack { BackupView().environmentObject(store) }
                    } else { ReaderView(store: store, session: session) }
                }
                    .frame(maxWidth: width, maxHeight: 1000).clipped()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .environment(\.dynamicTypeSize, ProcessInfo.processInfo.environment["TOOLBAR_MAX_TEXT"] == "1" ? .accessibility5 : (largeText ? .accessibility3 : .large))
                    .tint(Theme.accent).preferredColorScheme(.light)
            }
        }
    }

    enum ToolbarFixture {
        @MainActor static func persistedStrokes(_ store: LibraryStore, _ model: ReaderModel) -> Int {
            do {
                guard let data = try store.disk!.readInk(scoreID: model.scoreID, page: model.pageIndex) else { return 0 }
                return try PKDrawing(data: data).strokes.count
            } catch { return -1 }
        }
        @MainActor static func makeModel(store: LibraryStore, session: ReadingSession) -> ReaderModel {
            let model = ReaderModel(store: store, session: session)
            if ProcessInfo.processInfo.environment["VALIDATION_RELAUNCH_ID"] != nil || ProcessInfo.processInfo.environment["TOOLBAR_ACCEPTANCE"] == "1" { return model }
            if ProcessInfo.processInfo.environment["TOOLBAR_CROP"] == "1" { model.beginCrop(); return model }
            if ProcessInfo.processInfo.environment["TOOLBAR_HALF"] == "1" { model.turn(forward: true); return model }
            if ProcessInfo.processInfo.environment["TOOLBAR_READING"] == "1" { return model }
            model.beginAnnotation()
            for y in [500.0, 800.0] {
                model.canvasViewDidBeginUsingTool(model.canvas)
                let points = [CGPoint(x: 150, y: y), CGPoint(x: 400, y: y)].enumerated().map { index, point in
                    PKStrokePoint(location: point, timeOffset: Double(index), size: CGSize(width: 10, height: 10),
                        opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                }
                let stroke = PKStroke(ink: PKInk(.pen, color: .red), path: PKStrokePath(controlPoints: points, creationDate: Date()))
                model.canvas.drawing = PKDrawing(strokes: model.canvas.drawing.strokes + [stroke])
                model.canvasViewDidEndUsingTool(model.canvas)
            }
            model.undo()
            if ProcessInfo.processInfo.environment["TOOLBAR_FAILED_DRAFT"] == "1" {
                let draft = store.disk!.inkURL(model.scoreID, page: 0, draft: true)
                try! FileManager.default.removeItem(at: draft)
                try! FileManager.default.createDirectory(at: draft, withIntermediateDirectories: false)
                model.flushDraft()
            }
            if ProcessInfo.processInfo.environment["TOOLBAR_PENDING_SAVE"] == "1" {
                model.canvasViewDidBeginUsingTool(model.canvas)
            }
            if ProcessInfo.processInfo.environment["TOOLBAR_FAILED_SAVE"] == "1" {
                try! FileManager.default.createDirectory(at: store.disk!.inkURL(model.scoreID, page: 0), withIntermediateDirectories: false)
            }
            return model
        }
    }
    ''')

def uid(name):
    return hashlib.sha1(("reader-test:" + name).encode()).hexdigest()[:24].upper()

def plist(value):
    if isinstance(value, dict):
        return "{\n" + "\n".join(f"{json.dumps(k)} = {plist(v)};" for k, v in value.items()) + "\n}"
    if isinstance(value, list):
        return "(" + ",".join(plist(v) for v in value) + ")"
    return json.dumps(str(value))

project_path = WORK / "Percuscore.xcodeproj/project.pbxproj"
project = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(project_path)]))
objects = project["objects"]
project_object = objects[project["rootObject"]]
app_id = project_object["targets"][0]
app = objects[app_id]
builds = []
for path in sorted((WORK / "Tests/PercuscoreUITests").glob("*.swift")):
    relative = path.relative_to(WORK).as_posix()
    ref, build = uid(relative), uid(relative + ":build")
    objects[ref] = dict(isa="PBXFileReference", lastKnownFileType="sourcecode.swift", path=relative, sourceTree="SOURCE_ROOT")
    objects[build] = dict(isa="PBXBuildFile", fileRef=ref)
    builds.append(build)
    objects[project_object["mainGroup"]]["children"].append(ref)

test_id, product = uid("target"), uid("product")
objects[product] = dict(isa="PBXFileReference", explicitFileType="wrapper.cfbundle", path="ToolbarUITests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
objects[project_object["productRefGroup"]]["children"].append(product)
objects[uid("sources")] = dict(isa="PBXSourcesBuildPhase", buildActionMask="2147483647", files=builds, runOnlyForDeploymentPostprocessing="0")
objects[uid("frameworks")] = dict(isa="PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[], runOnlyForDeploymentPostprocessing="0")
objects[uid("proxy")] = dict(isa="PBXContainerItemProxy", containerPortal=project["rootObject"], proxyType="1", remoteGlobalIDString=app_id, remoteInfo="Percuscore")
objects[uid("dependency")] = dict(isa="PBXTargetDependency", target=app_id, targetProxy=uid("proxy"))
configs = []
for name in ["Debug", "Release"]:
    ident = uid(name)
    configs.append(ident)
    objects[ident] = dict(isa="XCBuildConfiguration", name=name, buildSettings=dict(
        PRODUCT_NAME="$(TARGET_NAME)", PRODUCT_BUNDLE_IDENTIFIER="com.percuscore.reader.toolbar-uitests",
        GENERATE_INFOPLIST_FILE="YES", SWIFT_VERSION="5.0", IPHONEOS_DEPLOYMENT_TARGET="17.0",
        TARGETED_DEVICE_FAMILY="2", CODE_SIGNING_ALLOWED="NO",
        TEST_TARGET_NAME="Percuscore",
        LD_RUNPATH_SEARCH_PATHS="$(inherited) @executable_path/Frameworks @loader_path/Frameworks"))
objects[uid("configs")] = dict(isa="XCConfigurationList", buildConfigurations=configs, defaultConfigurationIsVisible="0", defaultConfigurationName="Debug")
objects[test_id] = dict(isa="PBXNativeTarget", name="ToolbarUITests", productName="ToolbarUITests", productType="com.apple.product-type.bundle.ui-testing",
    productReference=product, buildConfigurationList=uid("configs"), buildPhases=[uid("sources"), uid("frameworks")],
    buildRules=[], dependencies=[uid("dependency")])
project_object["targets"].append(test_id)
for value in objects.values():
    if value.get("isa") == "XCBuildConfiguration" and value.get("buildSettings", {}).get("PRODUCT_BUNDLE_IDENTIFIER") == "com.percuscore.reader":
        value["buildSettings"]["PRODUCT_BUNDLE_IDENTIFIER"] = "com.percuscore.reader.toolbar-testhost"
if os.environ.get("LARGE_PDF_BENCHMARK") == "1":
    from large_pdf_benchmark_support import add_resource
    add_resource(objects, app, uid)
project_path.write_text("// !$*UTF8*$!\n" + plist(project))

scheme = WORK / "Percuscore.xcodeproj/xcshareddata/xcschemes/Percuscore.xcscheme"
scheme.write_text(scheme.read_text().replace("<Testables/>", f'''<Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_id}" BuildableName="ToolbarUITests.xctest" BlueprintName="ToolbarUITests" ReferencedContainer="container:Percuscore.xcodeproj"/></TestableReference></Testables>'''))
device = sys.argv[1]
environment = dict(os.environ)
environment.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
result = subprocess.run(["xcodebuild", "-project", str(WORK / "Percuscore.xcodeproj"), "-scheme", "Percuscore",
    "-destination", f"platform=iOS Simulator,id={device}", "-derivedDataPath", str(WORK / "build"),
    "-parallel-testing-enabled", "NO", "CODE_SIGNING_ALLOWED=NO", "test", *sys.argv[2:]], env=environment)
sys.exit(result.returncode)
