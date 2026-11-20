import CoreServices
import Darwin
import Foundation

/// Measures what a re-read of huge flat folders costs, and how many events FSEvents history holds at
/// folder vs file granularity (to choose how to make those re-reads cheap).
func hotProbe(paths: [String], waitSeconds: Int) {
    print("\n== Huge flat folders ==")
    for path in paths {
        for (label, priv, ext) in [("private size", true, false), ("no private size", false, false), ("ext flags only", false, true), ("private size", true, false)] {
            BulkDirectoryReader.requestPrivateSize = priv
            BulkDirectoryReader.requestExtFlags = ext
            let reader = BulkDirectoryReader()
            var n = 0, flagged = 0
            let t0 = now()
            reader.read(path: path) { e, _ in n += 1; if e.extFlags & 1 != 0 { flagged += 1 } }
            print(String(format: "  %6.3f s  %6d entries  %@%@  %@", now() - t0, n, label, ext ? " (may-share \(flagged))" : "", path.replacingOccurrences(of: home, with: "~")))
        }
    }
    BulkDirectoryReader.requestPrivateSize = true
    BulkDirectoryReader.requestExtFlags = false
    guard waitSeconds > 0 else { return }

    let start = FSEventsGetCurrentEventId()
    print("\n== FSEvents history over \(waitSeconds) s of normal use, home ==")
    sleep(UInt32(waitSeconds))
    for fileEvents in [false, true] {
        let t0 = now()
        let (count, paths) = replayCount(since: start, root: home, fileEvents: fileEvents)
        print(String(format: "  %@: %d events, %d distinct paths, replay %.2f s", fileEvents ? "file-level" : "folder-level", count, paths.count, now() - t0))
        if fileEvents {
            var perParent: [String: Int] = [:]
            for p in paths { perParent[(p as NSString).deletingLastPathComponent, default: 0] += 1 }
            for (dir, n) in perParent.sorted(by: { $0.value > $1.value }).prefix(8) {
                print("     \(n) in \(dir.replacingOccurrences(of: home, with: "~"))")
            }
        }
    }
}

private final class ProbeBox: @unchecked Sendable {
    var count = 0
    var dump = false
    var paths = Set<String>()
    let done = DispatchSemaphore(value: 0)
}

private func replayCount(since: UInt64, root: String, fileEvents: Bool) -> (Int, Set<String>) {
    let box = ProbeBox()
    box.dump = fileEvents
    var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: nil, release: nil, copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        let box = Unmanaged<ProbeBox>.fromOpaque(info!).takeUnretainedValue()
        let array = unsafeBitCast(paths, to: NSArray.self)
        for i in 0..<count {
            if Int(flags[i]) & kFSEventStreamEventFlagHistoryDone != 0 { box.done.signal(); continue }
            box.count += 1
            let path = array[i] as? String ?? ""
            box.paths.insert(path)
            if box.dump, path.contains("Cache_Data") || Int(flags[i]) & kFSEventStreamEventFlagItemIsFile == 0 {
                print(String(format: "     %08x %@", flags[i], path.replacingOccurrences(of: home, with: "~")))
            }
        }
    }
    var flags = kFSEventStreamCreateFlagUseCFTypes
    if fileEvents { flags |= kFSEventStreamCreateFlagFileEvents }
    let stream = FSEventStreamCreate(nil, callback, &context, [root] as CFArray, since, 0, FSEventStreamCreateFlags(flags))!
    let queue = DispatchQueue(label: "probe")
    FSEventStreamSetDispatchQueue(stream, queue)
    FSEventStreamStart(stream)
    _ = box.done.wait(timeout: .now() + 60)
    FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
    queue.sync {}
    return (box.count, box.paths)
}
