import SwiftUI
import PDFKit
import PencilKit
import UniformTypeIdentifiers

struct CreatedBackup { let url: URL; let sha256: String }

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var index = LibraryIndex()
    @Published var errorMessage: String?
    @Published var isImporting = false
    @Published private(set) var isManagingLibrary = false
    @Published var importProgress = ""
    @Published private(set) var isReady = false
    @Published private(set) var lastBackupExportAt: Date?
    @Published private(set) var backupHistoryUnavailable = false
    @Published private(set) var backupRecords = BackupRecords()
    @Published private(set) var backupEvidenceError: String?
    @Published private(set) var restoreRecoveryWarning: String?
    @Published private(set) var storageUsage: LibraryStorageUsage?
    @Published private(set) var isCalculatingStorage = false
    @Published private(set) var storageError: String?
    private var storageCalculationID = UUID()
    private(set) var disk: LibraryDisk?
    private let thumbnails = NSCache<NSString, UIImage>()
    private let storageRoot: URL?
    let isAcceptanceLibrary: Bool
    let isolationLabel: String?

    init(root: URL? = nil, isAcceptanceLibrary: Bool = false, isolationLabel: String? = nil) {
        storageRoot = root; self.isAcceptanceLibrary = isAcceptanceLibrary || isolationLabel != nil
        self.isolationLabel = isolationLabel; reload()
    }

    func reload() {
        guard !isManagingLibrary else { return }
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
            let storage = try LibraryDisk(root: storageRoot ?? documents.appendingPathComponent("Percuscore", isDirectory: true))
            let loaded = try storage.load()
            disk = storage; index = loaded; isReady = true; invalidateStorage()
            restoreRecoveryWarning = storage.restoreRecoveryWarning
            do { backupRecords = try storage.backupRecords(); backupEvidenceError = nil }
            catch { backupRecords = BackupRecords(); backupEvidenceError = "Backup evidence could not be read. No verification is assumed. \(error.localizedDescription)" }
            do {
                lastBackupExportAt = try backupRecords.exported?.date ?? storage.lastBackupExportDate()
                backupHistoryUnavailable = false
            } catch {
                lastBackupExportAt = nil; backupHistoryUnavailable = true
            }
            if storage.recoveredFromBackup {
                errorMessage = "Recovered the previous library index. Original PDFs and ink are preserved in Files → On My iPad → Percuscore."
            }
        } catch { isReady = false; errorMessage = error.localizedDescription }
    }

    func completeBackupExport(saved: Bool, at date: Date = Date(), archiveSHA256: String? = nil) throws {
        guard saved else { return }
        guard let disk else { throw CocoaError(.fileWriteUnknown) }
        if let archiveSHA256 {
            guard archiveSHA256.count == 64, archiveSHA256.allSatisfy(\.isHexDigit) else { throw BackupError.invalid }
            let prepared = backupRecords.prepared.flatMap { $0.sha256 == archiveSHA256 ? $0 : nil }
            var next = backupRecords; next.exported = BackupFileEvent(sha256: archiveSHA256, date: date,
                deletedScoreCount: prepared?.deletedScoreCount, deletedAssetBytes: prepared?.deletedAssetBytes)
            try disk.saveBackupRecords(next); backupRecords = next; backupEvidenceError = nil
        } else { try disk.recordBackupExport(at: date) }
        lastBackupExportAt = date; backupHistoryUnavailable = false
    }

    @discardableResult
    func update(_ edit: (inout LibraryIndex) -> Void) -> Bool {
        guard isReady, !isManagingLibrary, let disk else { return false }
        var next = index; edit(&next)
        do { try disk.save(next); index = next; invalidateStorage(); return true }
        catch { errorMessage = "Could not save: \(error.localizedDescription)"; return false }
    }

    func score(_ id: UUID) -> Score? { index.scores.first { $0.id == id && !$0.isDeleted } }
    func fileURL(_ id: UUID) -> URL? { disk?.pdfURL(for: id) }

    @discardableResult
    func moveToRecentlyDeleted(_ id: UUID) -> Bool {
        guard !isImporting else { return false }
        return update { $0.removeScore(id) }
    }
    @discardableResult
    func restoreDeletedScore(_ id: UUID) -> Bool {
        guard !isImporting, let score = index.scores.first(where: { $0.id == id }), score.isDeleted else { return false }
        guard score.purgePendingAt == nil else { errorMessage = LibraryError.cleanupPending.localizedDescription; return false }
        return update { $0.restoreScore(id) }
    }
    private func invalidateStorage() {
        storageCalculationID = UUID(); storageUsage = nil; isCalculatingStorage = false
    }
    func refreshStorage() async {
        guard isReady, !isCalculatingStorage, !isManagingLibrary, let disk else { return }
        let token = UUID(), snapshot = index
        storageCalculationID = token; isCalculatingStorage = true; storageError = nil
        do {
            let usage = try await Task.detached(priority: .utility) { try disk.storageUsage(index: snapshot) }.value
            guard storageCalculationID == token, snapshot == index else { return }
            storageUsage = usage; isCalculatingStorage = false
        } catch {
            guard storageCalculationID == token else { return }
            storageError = "Storage calculation did not finish. Refresh to retry. \(error.localizedDescription)"
            isCalculatingStorage = false
        }
    }
    @discardableResult
    func deletePermanently(_ id: UUID) async -> Bool {
        guard isReady, !isImporting, !isManagingLibrary, let disk else { return false }
        isManagingLibrary = true; invalidateStorage()
        defer { isManagingLibrary = false }
        do {
            index = try await Task.detached(priority: .utility) { try disk.permanentlyDelete(id) }.value
            thumbnails.removeObject(forKey: id.uuidString as NSString)
            return true
        } catch {
            // Intent may have committed even if cleanup failed. Publish durable pending state.
            do { index = try disk.load() } catch { isReady = false }
            errorMessage = "Permanent deletion did not finish. Open Recently Deleted and retry cleanup. \(error.localizedDescription)"
            return false
        }
    }
    func clearLibraryCache() async {
        guard isReady, !isImporting, !isManagingLibrary, let disk else { return }
        isManagingLibrary = true; invalidateStorage()
        do {
            try await Task.detached(priority: .utility) { try disk.clearCache() }.value
            thumbnails.removeAllObjects()
        } catch { errorMessage = "Cache cleanup did not finish. \(error.localizedDescription)" }
        isManagingLibrary = false
        await refreshStorage()
    }

    func importPDFs(_ urls: [URL], into setlistID: UUID? = nil) async -> [UUID] {
        guard isReady, !isImporting, !isManagingLibrary, let disk else { return [] }
        isImporting = true
        defer { isImporting = false; importProgress = "" }
        var imported: [UUID] = []; var failures: [String] = []
        for (offset, url) in urls.enumerated() {
            importProgress = "Importing \(offset + 1) of \(urls.count)…"
            let id = UUID(); let destination = disk.pdfURL(for: id)
            do {
                let score = try await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    var coordinationError: NSError?
                    var operationError: Error?
                    var importedScore: Score?
                    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                        do {
                            guard let document = PDFDocument(url: readable), !document.isLocked,
                                  document.pageCount > 0 else { throw LibraryError.invalidPDF }
                            try FileManager.default.copyItem(at: readable, to: destination)
                            importedScore = Score(id: id, title: url.deletingPathExtension().lastPathComponent,
                                                  pageCount: document.pageCount)
                        } catch { operationError = error }
                    }
                    if let error = coordinationError ?? (operationError as NSError?) { throw error }
                    guard let score = importedScore else { throw LibraryError.invalidPDF }
                    return score
                }.value
                let saved = update { library in
                    library.scores.append(score)
                    if let i = library.setlists.firstIndex(where: { $0.id == setlistID }) {
                        library.setlists[i].entries.append(.init(scoreID: score.id))
                    }
                }
                if saved { imported.append(id) }
                else { failures.append("\(url.lastPathComponent): copied, but the library index could not be saved.") }
            } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n\n") }
        return imported
    }

    /// Provider URLs expire when the callback returns, so copy to a staging file inside that callback.
    func receiveDrop(_ providers: [NSItemProvider], into setlistID: UUID? = nil,
                     completion: (([UUID]) -> Void)? = nil) -> Bool {
        let eligible = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) }
        guard !eligible.isEmpty, !isImporting, !isManagingLibrary else { return false }
        Task {
            var staged: [URL] = []
            for provider in eligible {
                do {
                    let url: URL = try await withCheckedThrowingContinuation { continuation in
                        provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, error in
                            guard let url else {
                                continuation.resume(throwing: error ?? LibraryError.invalidPDF); return
                            }
                            do {
                                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                                let copy = folder.appendingPathComponent(url.lastPathComponent)
                                try FileManager.default.copyItem(at: url, to: copy)
                                continuation.resume(returning: copy)
                            } catch { continuation.resume(throwing: error) }
                        }
                    }
                    staged.append(url)
                } catch { errorMessage = error.localizedDescription }
            }
            let ids = await importPDFs(staged, into: setlistID)
            for url in staged { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            completion?(ids)
        }
        return true
    }

    func setPage(_ page: Int, scoreID: UUID) {
        update { index in
            guard let i = index.scores.firstIndex(where: { $0.id == scoreID }) else { return }
            index.scores[i].lastPage = page; index.scores[i].lastOpenedAt = Date()
        }
    }
    func saveLayout(_ layout: PageLayout, page: Int, scoreID: UUID) -> Bool {
        update { library in
            guard let i = library.scores.firstIndex(where: { $0.id == scoreID }) else { return }
            var normalized = layout; normalized.normalize()
            library.scores[i].layouts[page] = normalized
        }
    }
    func saveBookmark(_ bookmark: ScoreBookmark, scoreID: UUID) -> Bool {
        guard let score = score(scoreID), bookmark.isValid(pageCount: score.pageCount) else {
            errorMessage = LibraryError.invalidBookmark.localizedDescription; return false
        }
        return update { index in
            guard let i = index.scores.firstIndex(where: { $0.id == scoreID }) else { return }
            if let j = index.scores[i].bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
                index.scores[i].bookmarks[j] = bookmark
            } else { index.scores[i].bookmarks.append(bookmark) }
            if !bookmark.isItem {
                for listIndex in index.setlists.indices {
                    index.setlists[listIndex].entries.removeAll {
                        $0.scoreID == scoreID && $0.bookmarkID == bookmark.id
                    }
                }
            }
        }
    }

    func thumbnail(for score: Score) async -> UIImage? {
        let key = score.id.uuidString as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let url = fileURL(score.id) else { return nil }
        let image = await Task.detached(priority: .utility) {
            PDFDocument(url: url)?.page(at: 0)?.thumbnail(of: CGSize(width: 420, height: 560), for: .mediaBox)
        }.value
        if let image { thumbnails.setObject(image, forKey: key) }
        return image
    }

    func addSample() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("First rehearsal — Percussion studies.pdf")
        do {
            try SampleScore.write(to: url)
            _ = await importPDFs([url])
        } catch { errorMessage = error.localizedDescription }
        try? FileManager.default.removeItem(at: url)
    }

    func createBackup() async throws -> URL {
        let prepared = try await createBackupFile()
        return prepared.url
    }
    func createBackupFile() async throws -> CreatedBackup {
        guard isReady, !isImporting, !isManagingLibrary, let disk else {
            throw CocoaError(.fileWriteUnknown)
        }
        isManagingLibrary = true
        defer { isManagingLibrary = false }
        let lease = disk.beginBackupSnapshot()
        defer { lease.release() }
        let snapshot = index
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Backup-\(UUID())")
        let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("Percuscore-\(date).percuscorebackup")
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try LibraryBackup.export(index: snapshot, disk: disk, to: url)
                return (try LibraryBackup.fileSHA256(url), try LibraryBackup.deletedSummary(from: url))
            }.value
            lease.release()
            let hash = prepared.0
            var records = backupRecords; records.prepared = BackupFileEvent(sha256: hash,
                deletedScoreCount: prepared.1.count, deletedAssetBytes: prepared.1.bytes)
            persistBackupRecords(records)
            return CreatedBackup(url: url, sha256: hash)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private func persistBackupRecords(_ records: BackupRecords) {
        backupRecords = records
        do { try disk?.saveBackupRecords(records); backupEvidenceError = nil }
        catch { backupEvidenceError = "Backup evidence could not be saved; the generated file or verified copy is still available in this session. \(error.localizedDescription)" }
    }
    var verifiedBackupRoot: URL? {
        guard let disk, let record = backupRecords.verification else { return nil }
        let root = disk.root.appendingPathComponent(".backup-verifications/\(record.id.uuidString)/restored")
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path) ? root : nil
    }
    func verifyBackup(from url: URL) async throws -> VerifiedBackup {
        guard isReady, !isImporting, !isManagingLibrary, let disk else { throw CocoaError(.fileReadUnknown) }
        isManagingLibrary = true; defer { isManagingLibrary = false }
        let id = UUID(), workspace = disk.root.appendingPathComponent(".backup-verifications/\(id.uuidString)")
        let result = try await Task.detached(priority: .userInitiated) {
            try BackupVerificationService.restoreSelectedFile(url, workspace: workspace)
        }.value
        let evidence = BackupVerificationService.evidence(result, id: id, records: backupRecords)
        var records = backupRecords; records.verification = evidence; persistBackupRecords(records)
        return VerifiedBackup(evidence: evidence, root: workspace.appendingPathComponent("restored"))
    }
    func updateBackupVisual(_ edit: (inout BackupVerificationEvidence) -> Void) {
        guard !isManagingLibrary, var evidence = backupRecords.verification,
              BackupVerificationService.matchesCurrentEnvironment(evidence) else { return }
        edit(&evidence)
        var records = backupRecords; records.verification = evidence; persistBackupRecords(records)
    }
    func removeVerificationCopies() throws {
        guard !isManagingLibrary, let disk else { throw CocoaError(.fileWriteUnknown) }
        let root = disk.root.appendingPathComponent(".backup-verifications")
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        objectWillChange.send()
    }

    func restoreBackup(from url: URL) async throws -> Int {
        guard isReady, !isImporting, !isManagingLibrary, let disk else {
            throw CocoaError(.fileWriteUnknown)
        }
        isManagingLibrary = true
        defer { isManagingLibrary = false }
        let snapshot = index
        let restored = try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var coordinationError: NSError?
            var result: Result<LibraryIndex, Error>?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                result = Result { try LibraryBackup.restore(from: readable, disk: disk, current: snapshot) }
            }
            if let result { return try result.get() }
            throw coordinationError ?? CocoaError(.fileReadUnknown) as NSError
        }.value
        index = restored; invalidateStorage()
        thumbnails.removeAllObjects()
        return restored.scores.count - snapshot.scores.count
    }

    func exportPDF(scoreID: UUID, includeMarkings: Bool) async throws -> URL {
        guard isReady, !isImporting, !isManagingLibrary, let disk, let score = score(scoreID) else {
            throw LibraryError.missingFile
        }
        isManagingLibrary = true
        defer { isManagingLibrary = false }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PDFExport-\(UUID())")
        let safeTitle = score.title.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r"))
            .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String(safeTitle.prefix(100))
        let suffix = includeMarkings ? " - marked" : " - original"
        let url = folder.appendingPathComponent((name.isEmpty ? "Score" : name) + suffix + ".pdf")
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try ScorePDFExport.write(score: score, disk: disk, includeMarkings: includeMarkings, to: url)
            }.value
            return url
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
