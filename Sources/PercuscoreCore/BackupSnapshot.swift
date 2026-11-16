import Foundation

/// A short mutex protects state; writers fail promptly while a backup reads files.
/// Locks are shared by canonical root, including separately constructed disks.
final class LibraryRootAccess {
    let lock = NSRecursiveLock()
    var readers = 0
    private final class WeakAccess { weak var value: LibraryRootAccess?; init(_ value: LibraryRootAccess) { self.value = value } }
    private static let registryLock = NSLock()
    private static var registry: [String: WeakAccess] = [:]
    static func shared(_ root: URL) -> LibraryRootAccess {
        registryLock.lock(); defer { registryLock.unlock() }
        registry = registry.filter { $0.value.value != nil }
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        if let existing = registry[key]?.value { return existing }
        let value = LibraryRootAccess(); registry[key] = WeakAccess(value); return value
    }
    func write<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard readers == 0 else { throw LibraryError.backupInProgress }
        return try body()
    }
}

public final class LibrarySnapshotLease: @unchecked Sendable {
    private let access: LibraryRootAccess
    private var released = false
    init(_ access: LibraryRootAccess) {
        self.access = access; access.lock.lock(); access.readers += 1; access.lock.unlock()
    }
    public func release() {
        access.lock.lock(); defer { access.lock.unlock() }
        guard !released else { return }
        released = true; access.readers -= 1
    }
    deinit { release() }
}
