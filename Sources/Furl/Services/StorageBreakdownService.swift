import Foundation

/// Raw numbers for the Overview storage bar. Everything here is read locally:
/// URL resource values for the volume, and `diskutil apfs list -plist` for per-volume usage.
struct VolumeSnapshot: Sendable, Equatable {
    /// Container size.
    let totalBytes: Int64
    /// Truly free space (`volumeAvailableCapacity`).
    let freeBytes: Int64
    /// Free space macOS would make for important work (`volumeAvailableCapacityForImportantUsage`).
    /// The difference to `freeBytes` is purgeable space: caches, iCloud copies, snapshots macOS can drop.
    let importantAvailableBytes: Int64
    /// Space used by the macOS volumes (System, Preboot, Recovery, Update, VM), if diskutil answered.
    let systemBytes: Int64?
    let volumeName: String

    var purgeableBytes: Int64 { max(0, importantAvailableBytes - freeBytes) }
    /// Used space, not counting purgeable space.
    var usedBytes: Int64 { max(0, totalBytes - importantAvailableBytes) }

    static let empty = VolumeSnapshot(totalBytes: 0, freeBytes: 0, importantAvailableBytes: 0, systemBytes: nil, volumeName: "Macintosh HD")
}

enum StorageBreakdownService {
    /// Reads the boot volume. Runs `diskutil` (about 0.2 s), so call it off the main thread.
    static func snapshot() -> VolumeSnapshot {
        let root = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey
        ]
        guard let values = try? root.resourceValues(forKeys: keys) else { return .empty }
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let free = Int64(values.volumeAvailableCapacity ?? 0)
        let important = values.volumeAvailableCapacityForImportantUsage ?? free
        return VolumeSnapshot(
            totalBytes: total,
            freeBytes: free,
            importantAvailableBytes: max(important, free),
            systemBytes: systemVolumesBytes(),
            volumeName: values.volumeName ?? "Macintosh HD"
        )
    }

    /// Sum of `CapacityInUse` for every APFS volume in the boot container whose role isn't Data.
    private static func systemVolumesBytes() -> Int64? {
        let info = ShellRunner.run("/usr/sbin/diskutil", arguments: ["info", "-plist", "/"], timeout: 10)
        guard info.exitCode == 0,
              let infoPlist = plist(info.stdout),
              let container = infoPlist["APFSContainerReference"] as? String else { return nil }

        let list = ShellRunner.run("/usr/sbin/diskutil", arguments: ["apfs", "list", "-plist", container], timeout: 10)
        guard list.exitCode == 0,
              let listPlist = plist(list.stdout),
              let containers = listPlist["Containers"] as? [[String: Any]],
              let match = containers.first(where: { ($0["ContainerReference"] as? String) == container }),
              let volumes = match["Volumes"] as? [[String: Any]] else { return nil }

        var total: Int64 = 0
        for volume in volumes {
            let roles = volume["Roles"] as? [String] ?? []
            guard !roles.isEmpty, !roles.contains("Data") else { continue }
            if let bytes = volume["CapacityInUse"] as? Int64 {
                total += bytes
            } else if let bytes = volume["CapacityInUse"] as? Int {
                total += Int64(bytes)
            }
        }
        return total > 0 ? total : nil
    }

    private static func plist(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}

// MARK: - Breakdown

/// One slice of the storage bar.
enum StorageSlice: String, CaseIterable, Identifiable, Sendable {
    case apps, junk, system, purgeable, other, free

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apps: return "Apps"
        case .junk: return "Caches & junk"
        case .system: return "macOS & system"
        case .purgeable: return "Purgeable"
        case .other: return "Your files & other"
        case .free: return "Free"
        }
    }
}

/// The bar's numbers, derived from a volume snapshot and the current scan results.
struct StorageBreakdown: Sendable {
    struct Entry: Identifiable, Sendable {
        let slice: StorageSlice
        let bytes: Int64
        /// The size is approximate (or not measured yet).
        let isEstimate: Bool
        let isMeasured: Bool
        var id: StorageSlice { slice }
    }

    let entries: [Entry]
    let totalBytes: Int64

    func entry(_ slice: StorageSlice) -> Entry? { entries.first { $0.slice == slice } }

    /// - Parameters:
    ///   - appsBytes: total size of installed app bundles, nil if Apps hasn't been scanned.
    ///   - junkBytes: what Furl's scans found it can clean (de-duplicated), nil if nothing was scanned.
    init(snapshot s: VolumeSnapshot, appsBytes: Int64?, junkBytes: Int64?) {
        totalBytes = s.totalBytes
        let used = s.usedBytes
        // Each measured slice is capped by what's left of used space, so the bar never overflows.
        var remaining = used
        func take(_ bytes: Int64?) -> Int64 {
            let value = min(max(0, bytes ?? 0), remaining)
            remaining -= value
            return value
        }
        let system = take(s.systemBytes)
        let apps = take(appsBytes)
        let junk = take(junkBytes)
        let other = remaining

        entries = [
            Entry(slice: .apps, bytes: apps, isEstimate: false, isMeasured: appsBytes != nil),
            Entry(slice: .junk, bytes: junk, isEstimate: false, isMeasured: junkBytes != nil),
            Entry(slice: .system, bytes: system, isEstimate: false, isMeasured: s.systemBytes != nil),
            Entry(slice: .purgeable, bytes: s.purgeableBytes, isEstimate: true, isMeasured: true),
            // Whatever's left: everything not measured above, so it is always an estimate.
            Entry(slice: .other, bytes: other, isEstimate: true, isMeasured: true),
            Entry(slice: .free, bytes: s.freeBytes, isEstimate: false, isMeasured: true)
        ]
    }
}
