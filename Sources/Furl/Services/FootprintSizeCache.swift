import Foundation

/// Fixed-size, lock-protected result buffer for `DispatchQueue.concurrentPerform`.
final class ConcurrentResults<T>: @unchecked Sendable {
    private var storage: [T]
    private let lock = NSLock()

    init(count: Int, initial: T) {
        storage = Array(repeating: initial, count: count)
    }

    func set(_ index: Int, _ value: T) {
        lock.lock()
        storage[index] = value
        lock.unlock()
    }

    var values: [T] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Remembers folder sizes between scans so a rescan of 200+ apps is quick.
///
/// - `.app` bundles are reused while their `Contents/Info.plist` is unchanged (an update rewrites it).
/// - Library folders are reused for `dataTTL` while their own modification date is unchanged (files
///   deep inside can change without touching it), and for `busyTTL` even when it changed: running
///   apps touch their folders every few seconds, and re-walking a 100k-file folder on every rescan
///   is what made rescans slow. Removed folders always size to 0.
///
/// Stored as JSON in ~/Library/Caches/Furl — local only, safe to delete.
final class FootprintSizeCache: @unchecked Sendable {
    static let shared = FootprintSizeCache()

    static let dataTTL: TimeInterval = 30 * 60
    static let busyTTL: TimeInterval = 5 * 60

    private struct Entry: Codable {
        var stamp: Double
        var size: Int64
        var measuredAt: Date
    }

    private var entries: [String: Entry]
    private let lock = NSLock()

    private static var fileURL: URL {
        return AppIdentity.cachesDirectory.appendingPathComponent("app-footprint-sizes.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    /// Sizes for all `paths`, measuring the uncached ones in parallel. Missing paths size to 0.
    func sizes(for paths: [String]) -> [String: Int64] {
        let unique = Array(Set(paths))
        let box = ConcurrentResults<Int64>(count: unique.count, initial: 0)
        DispatchQueue.concurrentPerform(iterations: unique.count) { i in
            box.set(i, self.size(of: unique[i]))
        }
        let values = box.values
        var result: [String: Int64] = [:]
        result.reserveCapacity(unique.count)
        for (i, path) in unique.enumerated() {
            result[path] = values[i]
        }
        save(keeping: Set(unique))
        return result
    }

    private func size(of path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let isBundle = url.pathExtension.lowercased() == "app"
        let stampURL = isBundle ? url.appendingPathComponent("Contents/Info.plist") : url
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: stampURL.path),
              let modified = attrs[.modificationDate] as? Date else {
            // Gone (or unreadable): nothing to free here.
            return FileManager.default.fileExists(atPath: path) ? FileSizeHelper.directorySize(at: url) : 0
        }
        let stamp = modified.timeIntervalSinceReferenceDate

        lock.lock()
        let cached = entries[path]
        lock.unlock()
        if let cached {
            let age = Date().timeIntervalSince(cached.measuredAt)
            let fresh = cached.stamp == stamp
                ? (isBundle || age < Self.dataTTL)
                : (!isBundle && age < Self.busyTTL)
            if fresh { return cached.size }
        }

        let measured = Self.parallelSize(of: url, depth: 0)
        lock.lock()
        entries[path] = Entry(stamp: stamp, size: measured, measuredAt: Date())
        lock.unlock()
        return measured
    }

    /// Like `FileSizeHelper.directorySize`, but fans the first two folder levels out across cores,
    /// so one huge folder (an app's 100k-file support folder) doesn't hold up the whole scan.
    private static func parallelSize(of url: URL, depth: Int) -> Int64 {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        guard depth < 2,
              let values = try? url.resourceValues(forKeys: Set(keys)),
              values.isDirectory == true, values.isSymbolicLink != true,
              let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
        else {
            return FileSizeHelper.directorySize(at: url)
        }
        let box = ConcurrentResults<Int64>(count: children.count, initial: 0)
        DispatchQueue.concurrentPerform(iterations: children.count) { i in
            let child = children[i]
            if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return }
            box.set(i, parallelSize(of: child, depth: depth + 1))
        }
        return box.values.reduce(0, +)
    }

    /// Drops entries for paths that no longer show up in a scan, then writes the cache.
    private func save(keeping live: Set<String>) {
        lock.lock()
        entries = entries.filter { live.contains($0.key) }
        let snapshot = entries
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
