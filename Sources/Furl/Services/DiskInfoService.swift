import Foundation

enum DiskInfoService {
    static func currentDiskUsage() -> DiskUsageInfo {
        let rootURL = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]

        guard let values = try? rootURL.resourceValues(forKeys: keys) else {
            return .empty
        }

        let total = Int64(values.volumeTotalCapacity ?? 0)
        let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        let used = max(0, total - available)
        let name = values.volumeName ?? "Macintosh HD"

        return DiskUsageInfo(
            totalBytes: total,
            availableBytes: available,
            usedBytes: used,
            volumeName: name
        )
    }

    static func trashSize() -> Int64 {
        let trashURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        return FileSizeHelper.directorySize(at: trashURL)
    }
}
