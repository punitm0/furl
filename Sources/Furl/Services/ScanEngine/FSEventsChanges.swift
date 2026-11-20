import CoreServices
import Darwin
import Foundation

/// Directories that changed since a stored FSEvents event ID, reduced to what the incremental updater needs.
///
/// The stream is file-level: each event names the item that changed. An item event means its parent's
/// listing changed, which is what a folder-level stream would have reported, so it maps to the parent —
/// except a plain file, which is kept by path so a huge folder can re-read only that file.
struct ChangeSet: Sendable {
    /// Directories whose direct contents changed (re-read shallowly).
    var shallow: Set<String> = []
    /// Regular files that changed (created, removed, renamed, written, attributes). The updater re-reads
    /// the file alone when its folder has a per-file table, and treats it as a change of its folder otherwise.
    var files: Set<String> = []
    /// Directories whose whole subtree must be re-walked (kFSEventStreamEventFlagMustScanSubDirs).
    var deep: Set<String> = []
    /// History can't be trusted (dropped events, IDs wrapped, root/volume changed): do a full walk.
    var requiresFullRescan = false
    var fullRescanReason: String?
    /// Highest event ID seen; store it with the updated index.
    var latestEventID: UInt64 = 0
    var eventCount = 0

    var isEmpty: Bool { shallow.isEmpty && deep.isEmpty && files.isEmpty && !requiresFullRescan }

    mutating func merge(_ other: ChangeSet) {
        shallow.formUnion(other.shallow)
        files.formUnion(other.files)
        deep.formUnion(other.deep)
        if other.requiresFullRescan {
            requiresFullRescan = true
            fullRescanReason = fullRescanReason ?? other.fullRescanReason
        }
        latestEventID = max(latestEventID, other.latestEventID)
        eventCount += other.eventCount
    }

    mutating func add(path rawPath: String, flags: FSEventStreamEventFlags, id: UInt64, roots: [String]) {
        eventCount += 1
        latestEventID = max(latestEventID, id)
        let f = Int(flags)
        if f & kFSEventStreamEventFlagHistoryDone != 0 { return }
        if f & (kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 {
            requiresFullRescan = true
            fullRescanReason = fullRescanReason ?? "FSEvents dropped events"
            return
        }
        if f & kFSEventStreamEventFlagEventIdsWrapped != 0 {
            requiresFullRescan = true
            fullRescanReason = fullRescanReason ?? "FSEvents IDs wrapped"
            return
        }
        if f & kFSEventStreamEventFlagRootChanged != 0 {
            requiresFullRescan = true
            fullRescanReason = fullRescanReason ?? "Scan root moved or was deleted"
            return
        }
        var path = rawPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if f & (kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount) != 0 {
            // A volume appeared/disappeared below the root; only matters if it's inside what we index.
            if roots.contains(where: { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }) {
                requiresFullRescan = true
                fullRescanReason = fullRescanReason ?? "A volume was mounted or unmounted inside the scan root"
            }
            return
        }
        if f & kFSEventStreamEventFlagMustScanSubDirs != 0 {
            deep.insert(path)
            return
        }
        let itemKinds = kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsDir
            | kFSEventStreamEventFlagItemIsSymlink | kFSEventStreamEventFlagItemIsHardlink
            | kFSEventStreamEventFlagItemIsLastHardlink
        // A folder-level event (no item kind) or one about a root itself: re-read that folder.
        if f & itemKinds == 0 || roots.contains(path) {
            shallow.insert(path)
            return
        }
        // A clone shares blocks with its source, whose size then changes without an event of its own, so a
        // cloned file is a change of its whole folder. So is anything that was or became a folder or link.
        let notPlainFile = kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemIsSymlink
            | kFSEventStreamEventFlagItemCloned
        if f & kFSEventStreamEventFlagItemIsFile != 0 && f & notPlainFile == 0 {
            files.insert(path)
        } else {
            shallow.insert((path as NSString).deletingLastPathComponent)
        }
    }
}

enum FSEventsHistory {
    static func currentEventID() -> UInt64 { FSEventsGetCurrentEventId() }

    /// The FSEvents database UUID of the volume holding `path`. It changes when that database is reset, which
    /// invalidates every stored event ID.
    static func databaseUUID(forPath path: String) -> String {
        var st = stat()
        guard stat(path, &st) == 0, let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return "" }
        return (CFUUIDCreateString(nil, uuid) as String?) ?? ""
    }

    /// Replays the FSEvents history for `roots` since `eventID` and returns the changed directories.
    /// Returns a change set with `requiresFullRescan` if the history can't be read in time.
    static func changes(since eventID: UInt64, roots: [String], timeout: TimeInterval = 20) async -> ChangeSet {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let collector = FSEventsCollector(roots: roots)
                let finished = collector.replay(since: eventID, timeout: timeout)
                var result = collector.drain()
                if !finished {
                    result.requiresFullRescan = true
                    result.fullRescanReason = result.fullRescanReason ?? "Timed out reading FSEvents history"
                }
                continuation.resume(returning: result)
            }
        }
    }
}

/// Owns one FSEventStream. Used both to replay history once (`replay`) and as a live watcher while the
/// app runs (`startLive` + periodic `drain`).
final class FSEventsCollector: @unchecked Sendable {
    let roots: [String]
    private let lock = NSLock()
    private var pending = ChangeSet()
    private var historyDone = DispatchSemaphore(value: 0)
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "Furl.FSEventsCollector", qos: .utility)

    init(roots: [String]) {
        self.roots = roots
    }

    deinit { stop() }

    /// Replays history since `eventID`; returns false on timeout.
    func replay(since eventID: UInt64, timeout: TimeInterval) -> Bool {
        historyDone = DispatchSemaphore(value: 0)
        guard start(since: eventID, latency: 0) else {
            lock.lock()
            pending.requiresFullRescan = true
            pending.fullRescanReason = "Couldn't open an FSEvents stream"
            lock.unlock()
            return true
        }
        let ok = historyDone.wait(timeout: .now() + timeout) == .success
        stop()
        return ok
    }

    /// Keeps collecting changes from now on until `stop()`.
    @discardableResult
    func startLive(latency: TimeInterval = 2) -> Bool {
        start(since: FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency: latency)
    }

    /// Returns and clears everything collected so far.
    func drain() -> ChangeSet {
        lock.lock(); defer { lock.unlock() }
        let result = pending
        pending = ChangeSet()
        pending.latestEventID = result.latestEventID
        return result
    }

    func stop() {
        lock.lock()
        let s = stream
        stream = nil
        lock.unlock()
        guard let s else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        queue.sync {} // let any in-flight callback finish before dropping the stream's reference to self
        Unmanaged.passUnretained(self).release() // balance the retain taken in start()
    }

    private func start(since eventID: UInt64, latency: TimeInterval) -> Bool {
        stop()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let collector = Unmanaged<FSEventsCollector>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            collector.receive(count: count, paths: array, flags: flags, ids: ids)
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, roots as CFArray, eventID, latency, flags
        ) else {
            Unmanaged.passUnretained(self).release()
            return false
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            Unmanaged.passUnretained(self).release()
            return false
        }
        lock.lock(); stream = created; lock.unlock()
        return true
    }

    private func receive(count: Int, paths: NSArray, flags: UnsafePointer<FSEventStreamEventFlags>, ids: UnsafePointer<FSEventStreamEventId>) {
        var sawHistoryDone = false
        lock.lock()
        for i in 0..<count {
            let path = (paths[i] as? String) ?? ""
            if Int(flags[i]) & kFSEventStreamEventFlagHistoryDone != 0 { sawHistoryDone = true }
            pending.add(path: path, flags: flags[i], id: ids[i], roots: roots)
        }
        lock.unlock()
        if sawHistoryDone { historyDone.signal() }
    }
}
