import Foundation
import CoreServices

/// A directory-tree notification is only an invalidation hint. Explicit reads still inspect file metadata,
/// and the app performs a periodic reconciliation if notifications are delayed, coalesced or unavailable.
final class LibraryFileMonitor: @unchecked Sendable {
    private final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var value: UInt64 = 0
        func increment() { lock.lock(); value &+= 1; lock.unlock() }
        func read() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    }
    private let counter = Counter()
    private var stream: FSEventStreamRef?
    var generation: UInt64 { counter.read() }

    init(directory: URL) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(counter).toOpaque(), retain: { info in
            if let info { _ = Unmanaged<Counter>.fromOpaque(info).retain() }
            return info
        }, release: { info in
            if let info { Unmanaged<Counter>.fromOpaque(info).release() }
        }, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            if let info { Unmanaged<Counter>.fromOpaque(info).takeUnretainedValue().increment() }
        }, &context, [directory.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "myclip.files", qos: .utility))
            if !FSEventStreamStart(stream) { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
        }
    }
    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}

public struct LibraryChangeStamp: Equatable, Sendable {
    let local: String
    let external: String
    let memory: UInt64
    let images: UInt64
}

public struct LibraryRefreshVersions: Sendable {
    public let library: String
    public let tasks: String
    public let statistics: String
    public let tokens: String
}

extension LibraryStore {
    /// Small per-domain invalidation tokens. Progress/tool logging does not invalidate the board or library.
    /// External SQLite connections conservatively invalidate every domain via PRAGMA data_version.
    public func refreshVersions() throws -> LibraryRefreshVersions {
        let external = try database.run("PRAGMA data_version").first?["data_version"] ?? "0"
        func token(_ tables: [String]) -> String { external + ":" + String(database.tableRevision(tables)) }
        return LibraryRefreshVersions(
            library: token(["captures", "images", "image_text", "entries", "memory_files", "jobs", "job_sources", "job_memory_changes", "dream_plans", "pending_captures", "organization_queue"]) + ":\(memoryMonitor.generation):\(imageMonitor.generation)",
            tasks: token(["work_tasks", "work_task_events", "work_task_evidence", "task_ingestions"]),
            statistics: token(["captures", "images", "entries", "jobs", "job_times", "mcp_reads"]) + ":\(imageMonitor.generation)",
            tokens: token(["token_usage"]))
    }

    /// Includes writes from independent MCP/board connections, not just writes made by this actor.
    public func changeStamp() throws -> LibraryChangeStamp {
        LibraryChangeStamp(local: try database.run("SELECT total_changes() n").first?["n"] ?? "0",
                           external: try database.run("PRAGMA data_version").first?["data_version"] ?? "0",
                           memory: memoryMonitor.generation, images: imageMonitor.generation)
    }
}

/// Bound the in-memory working set. Revision histories are immutable in normal operation, but their
/// metadata is checked too so copied libraries, external edits and atomic replacements stay observable.
struct MemoryReadCache {
    struct Stamp: Equatable {
        let modified: Date?
        let created: Date?
        let size: UInt64
        let inode: UInt64
        init(_ url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            modified = attributes[.modificationDate] as? Date
            created = attributes[.creationDate] as? Date
            size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        }
    }
    struct File {
        let stamp: Stamp
        let text: String
        var document: MemoryDocument?
        var hash: String?
    }
    private var files: [URL: File] = [:]
    private(set) var reads = 0
    mutating func reset() { files.removeAll(keepingCapacity: true) }
    mutating func text(at url: URL) throws -> String {
        let stamp = try Stamp(url)
        if let cached = files[url], cached.stamp == stamp { return cached.text }
        let text = try String(contentsOf: url, encoding: .utf8)
        reads += 1
        if files.count >= 512 { files.removeAll(keepingCapacity: true) }
        files[url] = File(stamp: stamp, text: text)
        return text
    }
    mutating func hash(at url: URL) throws -> String {
        let text = try text(at: url)
        if let hash = files[url]?.hash { return hash }
        let hash = LibraryStore.memoryHash(text)
        files[url]?.hash = hash
        return hash
    }
    mutating func document(at url: URL) throws -> MemoryDocument {
        let text = try text(at: url)
        if let document = files[url]?.document { return document }
        let document = try MemoryDocument(text)
        files[url]?.document = document
        return document
    }
}

public enum BackgroundWorkBudget {
    /// Never stop captures, explicit searches or manual work because of the power profile.
    public static var allowsMaintenance: Bool {
        maintenanceAllowed(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: ProcessInfo.processInfo.thermalState)
    }
    public static var allowsOCR: Bool {
        ocrAllowed(thermal: ProcessInfo.processInfo.thermalState)
    }
    static func maintenanceAllowed(lowPower: Bool, thermal: ProcessInfo.ThermalState) -> Bool {
        !lowPower && ocrAllowed(thermal: thermal)
    }
    static func ocrAllowed(thermal: ProcessInfo.ThermalState) -> Bool {
        thermal != .serious && thermal != .critical
    }
}
