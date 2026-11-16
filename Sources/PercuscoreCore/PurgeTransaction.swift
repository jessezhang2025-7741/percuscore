import Foundation

enum PurgeCheckpoint { case intentRecorded, removedAsset(Int), beforeIndexCommit, indexCommitted }

/// Durable intent prevents an old reader or index backup from recreating permanently deleted data.
enum PurgeTransaction {
    struct Record: Codable {
        var version = 1
        let scoreID: UUID
        let startedAt: Date
        var completed = false
        var score: Score?
    }
    static func directory(_ disk: LibraryDisk) -> URL { disk.root.appendingPathComponent(".purges", isDirectory: true) }
    static func url(_ id: UUID, disk: LibraryDisk) -> URL { directory(disk).appendingPathComponent("\(id.uuidString).json") }
    static func records(_ disk: LibraryDisk) throws -> [Record] {
        let folder = directory(disk), fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return [] }
        try ScoreAssetOwnership.requireDirectory(folder)
        return try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).map { file in
            let record = try JSONDecoder().decode(Record.self, from: LibraryDisk.readBounded(file, maximumBytes: 16 * 1024 * 1024))
            guard file.lastPathComponent == "\(record.scoreID.uuidString).json", record.version == 1,
                  record.completed ? record.score == nil : record.score?.id == record.scoreID && record.score?.deletedAt != nil else {
                throw LibraryError.unsafeStorage
            }
            if let score = record.score { var index = LibraryIndex(); index.scores = [score]; try index.validate() }
            return record
        }
    }
    static func write(_ record: Record, disk: LibraryDisk) throws {
        let folder = directory(disk)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        try ScoreAssetOwnership.requireDirectory(folder)
        let destination = url(record.scoreID, disk: disk)
        try JSONEncoder().encode(record).write(to: destination, options: .atomic)
        let file = try FileHandle(forWritingTo: destination); defer { try? file.close() }; try file.synchronize()
    }
    static func requireWritable(_ id: UUID, disk: LibraryDisk) throws {
        let folder = directory(disk)
        if FileManager.default.fileExists(atPath: folder.path) { try ScoreAssetOwnership.requireDirectory(folder) }
        guard !FileManager.default.fileExists(atPath: url(id, disk: disk).path) else { throw LibraryError.cleanupPending }
    }
    static func reconcile(_ original: LibraryIndex, disk: LibraryDisk) throws -> LibraryIndex {
        var index = original
        for record in try records(disk) {
            if record.completed { index.finishRemovingScore(record.scoreID) }
            else if let i = index.scores.firstIndex(where: { $0.id == record.scoreID }) {
                index.scores[i].deletedAt = record.score!.deletedAt
                index.scores[i].purgePendingAt = record.startedAt
            } else {
                var score = record.score!; score.purgePendingAt = record.startedAt; index.scores.append(score)
            }
        }
        try index.validate(); return index
    }
    static func validateSave(_ index: LibraryIndex, disk: LibraryDisk, finishing: UUID? = nil) throws {
        for record in try records(disk) {
            let score = index.scores.first { $0.id == record.scoreID }
            if record.completed {
                guard score == nil else { throw LibraryError.cleanupPending }
            } else {
                if record.scoreID == finishing, score == nil { continue }
                guard score?.purgePendingAt == record.startedAt, score?.deletedAt == record.score?.deletedAt else { throw LibraryError.cleanupPending }
            }
        }
    }
    static func assets(_ id: UUID, disk: LibraryDisk) throws -> [URL] {
        var files: [URL] = []
        for folder in [disk.pdfDirectory, disk.inkDirectory, disk.recoveryDirectory] {
            try ScoreAssetOwnership.requireDirectory(folder)
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where ScoreAssetOwnership.owner(file.lastPathComponent, directory: folder.lastPathComponent) == id {
                _ = try ScoreAssetOwnership.regularSize(file)
                files.append(file)
            }
        }
        return files.sorted { $0.path < $1.path }
    }
}

extension LibraryDisk {
    public func permanentlyDelete(_ id: UUID) throws -> LibraryIndex {
        try permanentlyDelete(id, checkpoint: { _ in })
    }
    /// Checkpoints exercise real durable boundaries without changing production behavior.
    func permanentlyDelete(_ id: UUID, checkpoint: (PurgeCheckpoint) throws -> Void) throws -> LibraryIndex {
        try withExclusiveWrite {
            var index = try load()
            var record: PurgeTransaction.Record
            if let existing = try PurgeTransaction.records(self).first(where: { $0.scoreID == id }) {
                if existing.completed { try save(index); return index }
                record = existing
            } else {
                guard let score = index.scores.first(where: { $0.id == id }), score.isDeleted else { throw LibraryError.cleanupPending }
                _ = try PurgeTransaction.assets(id, disk: self) // Validate ownership before recording intent.
                record = .init(scoreID: id, startedAt: Date(), score: score)
                try PurgeTransaction.write(record, disk: self)
                try checkpoint(.intentRecorded)
            }
            index = try PurgeTransaction.reconcile(index, disk: self)
            try save(index)
            for (offset, file) in try PurgeTransaction.assets(id, disk: self).enumerated() {
                try FileManager.default.removeItem(at: file)
                try checkpoint(.removedAsset(offset + 1))
            }
            guard try PurgeTransaction.assets(id, disk: self).isEmpty else { throw LibraryError.unsafeStorage }
            try checkpoint(.beforeIndexCommit)
            // Keep intent pending until both files and index are complete. Any failure stays retryable.
            index.finishRemovingScore(id)
            try savePurgeResult(index, scoreID: id)
            try checkpoint(.indexCommitted)
            record.completed = true; record.score = nil
            try PurgeTransaction.write(record, disk: self)
            return index
        }
    }
}
