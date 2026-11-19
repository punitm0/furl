import CoreServices
import Foundation

/// Instant, APPROXIMATE answers from the Spotlight index — for a first screen while the real walk runs.
///
/// Caveats (why results are marked approximate and must be replaced by the walk's results):
///  - Spotlight skips folders the user excluded, hidden/system folders, most of ~/Library, and anything
///    not yet indexed; it can lag behind recent changes.
///  - `kMDItemFSSize` is the logical size, not clone-aware reclaimable space.
///
/// Uses the synchronous `MDQuery` C API (the engine under `NSMetadataQuery`) so it can run on any thread
/// without a run loop; `NSMetadataQuery` would need the main run loop and notification plumbing.
enum SpotlightFastPath {
    struct Hit: Sendable, Hashable {
        let path: String
        /// Logical size from Spotlight — NOT the reclaimable size.
        let logicalSize: Int64
        let modified: Date?
        let lastUsed: Date?
        let isApproximate = true
    }

    /// Files of at least `minBytes` under `scopes`, largest first.
    static func largeFiles(minBytes: Int64, scopes: [String], limit: Int = 2_000) async -> [Hit] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runQuery(
                    "kMDItemFSSize >= \(minBytes) && kMDItemContentTypeTree != \"public.folder\" && kMDItemContentTypeTree != \"com.apple.package\"",
                    scopes: scopes, limit: limit
                ))
            }
        }
    }

    /// Last-opened dates for specific files (nil when Spotlight never saw them opened or doesn't index them).
    static func lastUsedDates(for paths: [String]) -> [String: Date] {
        var result: [String: Date] = [:]
        for path in paths {
            guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
                  let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date else { continue }
            result[path] = date
        }
        return result
    }

    private static func runQuery(_ queryString: String, scopes: [String], limit: Int) -> [Hit] {
        guard let query = MDQueryCreate(kCFAllocatorDefault, queryString as CFString, nil, nil) else { return [] }
        if !scopes.isEmpty {
            MDQuerySetSearchScope(query, scopes as CFArray, 0)
        }
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        defer { MDQueryStop(query) }

        var hits: [Hit] = []
        let count = MDQueryGetResultCount(query)
        hits.reserveCapacity(min(count, limit * 2))
        for i in 0..<count {
            guard let raw = MDQueryGetResultAtIndex(query, i) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            let size = (MDItemCopyAttribute(item, kMDItemFSSize) as? NSNumber)?.int64Value ?? 0
            hits.append(Hit(
                path: path,
                logicalSize: size,
                modified: MDItemCopyAttribute(item, kMDItemContentModificationDate) as? Date,
                lastUsed: MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
            ))
        }
        hits.sort { $0.logicalSize > $1.logicalSize }
        return Array(hits.prefix(limit))
    }
}
