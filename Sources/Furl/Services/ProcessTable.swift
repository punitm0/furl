import Darwin
import Foundation

/// One process as read from the kernel via libproc / sysctl. No subprocesses are spawned.
struct ProcInfo: Sendable, Hashable {
    let pid: Int32
    let ppid: Int32
    let pgid: Int32
    let uid: UInt32
    /// Microseconds since 1970; together with `pid` uniquely identifies a process (guards against PID reuse).
    let startMicros: UInt64
    let isZombie: Bool
    /// Short kernel name (`pbi_name`).
    let name: String
    /// Full executable path, empty when unavailable.
    let path: String
    let args: [String]
    let cwd: String?
    /// Physical footprint (what Activity Monitor shows as Memory), falling back to RSS.
    let memoryBytes: UInt64
    /// Total CPU time used so far, in nanoseconds.
    let cpuNanos: UInt64
    /// Only the whitelisted keys from `AgentDefinition.watchedEnvKeys`.
    let markers: [String: String]

    var key: String { "\(pid)@\(startMicros)" }
    var startDate: Date { Date(timeIntervalSince1970: Double(startMicros) / 1_000_000) }

    /// Basename of the executable (falls back to argv[0] and then the kernel name).
    var executableName: String {
        if !path.isEmpty { return (path as NSString).lastPathComponent }
        if let first = args.first, !first.isEmpty { return (first as NSString).lastPathComponent }
        return name
    }
}

enum ProcessTable {
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(max(info.numer, 1)), UInt64(max(info.denom, 1)))
    }()

    /// Snapshot of every process owned by the current user.
    static func snapshot() -> [Int32: ProcInfo] {
        let uid = getuid()
        var result: [Int32: ProcInfo] = [:]
        var scratch = ArgsBuffer()
        for pid in allPIDs() where pid > 0 {
            guard let info = read(pid: pid, requireUID: uid, scratch: &scratch) else { continue }
            result[pid] = info
        }
        return result
    }

    static func allPIDs() -> [Int32] {
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimated) + 64)
        let count = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<Int32>.size))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    /// Minimal identity check used before signalling: uid, start time and zombie state.
    static func identity(of pid: Int32) -> (uid: UInt32, startMicros: UInt64, ppid: Int32, isZombie: Bool)? {
        guard let bsd = bsdInfo(pid) else { return nil }
        let start = UInt64(bsd.pbi_start_tvsec) * 1_000_000 + UInt64(bsd.pbi_start_tvusec)
        return (bsd.pbi_uid, start, Int32(bsd.pbi_ppid), bsd.pbi_status == UInt32(SZOMB))
    }

    /// True while the process still has a terminal it can read from (an open terminal tab or window).
    /// A process whose terminal closed reports no device. Unreadable processes count as attached, so
    /// callers that only act on detached processes leave them alone.
    static func isAttachedToTerminal(_ pid: Int32) -> Bool {
        guard let bsd = bsdInfo(pid) else { return true }
        return bsd.e_tdev != UInt32.max
    }

    static func read(pid: Int32, requireUID: UInt32? = nil) -> ProcInfo? {
        var scratch = ArgsBuffer()
        return read(pid: pid, requireUID: requireUID, scratch: &scratch)
    }

    /// Reusable buffer for `KERN_PROCARGS2` so a full snapshot allocates it once.
    struct ArgsBuffer {
        var bytes: [UInt8]
        init() {
            var argMax: Int32 = 0
            var size = MemoryLayout<Int32>.size
            var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
            if sysctl(&mib, 2, &argMax, &size, nil, 0) != 0 || argMax <= 0 { argMax = 1 << 20 }
            bytes = [UInt8](repeating: 0, count: Int(argMax))
        }
    }

    static func read(pid: Int32, requireUID: UInt32?, scratch: inout ArgsBuffer) -> ProcInfo? {
        guard let bsd = bsdInfo(pid) else { return nil }
        if let requireUID, bsd.pbi_uid != requireUID { return nil }

        var bsdCopy = bsd
        let name = withUnsafeBytes(of: &bsdCopy.pbi_name) { cString(from: $0) }
        let comm = withUnsafeBytes(of: &bsdCopy.pbi_comm) { cString(from: $0) }

        let (args, markers) = argumentsAndMarkers(pid, buffer: &scratch.bytes)
        let start = UInt64(bsd.pbi_start_tvsec) * 1_000_000 + UInt64(bsd.pbi_start_tvusec)

        var memory: UInt64 = 0
        var cpu: UInt64 = 0
        var usage = rusage_info_v2()
        let usageResult = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        if usageResult == 0 {
            memory = usage.ri_phys_footprint
            cpu = machToNanos(usage.ri_user_time &+ usage.ri_system_time)
        } else {
            var task = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size {
                memory = task.pti_resident_size
                cpu = machToNanos(task.pti_total_user &+ task.pti_total_system)
            }
        }

        return ProcInfo(
            pid: pid,
            ppid: Int32(bsd.pbi_ppid),
            pgid: Int32(bsd.pbi_pgid),
            uid: bsd.pbi_uid,
            startMicros: start,
            isZombie: bsd.pbi_status == UInt32(SZOMB),
            name: name.isEmpty ? comm : name,
            path: executablePath(pid),
            args: args,
            cwd: currentDirectory(pid),
            memoryBytes: memory,
            cpuNanos: cpu,
            markers: markers
        )
    }

    // MARK: - libproc helpers

    private static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    private static func executablePath(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func currentDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { cString(from: $0) }
        return path.isEmpty ? nil : path
    }

    /// Reads argv and the environment via `KERN_PROCARGS2`. Environment values are filtered
    /// down to `AgentDefinition.watchedEnvKeys` immediately; nothing else is retained.
    private static func argumentsAndMarkers(_ pid: Int32, buffer: inout [UInt8]) -> ([String], [String: String]) {
        var size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return ([], [:]) }

        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size

        // Skip the saved exec path and its NUL padding.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        func nextString() -> String? {
            guard index < size else { return nil }
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            let string = String(decoding: buffer[start..<index], as: UTF8.self)
            index += 1
            return string
        }

        var args: [String] = []
        args.reserveCapacity(argc)
        for _ in 0..<argc {
            guard let arg = nextString() else { break }
            args.append(arg)
        }

        var markers: [String: String] = [:]
        let watched = AgentDefinition.watchedEnvKeys
        while let entry = nextString(), !entry.isEmpty {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<eq])
            if watched.contains(key) {
                markers[key] = String(entry[entry.index(after: eq)...])
            }
        }
        // Wipe the bytes that held the full environment as soon as the markers are extracted.
        buffer.withUnsafeMutableBytes { raw in
            _ = memset(raw.baseAddress!, 0, size)
        }
        return (args, markers)
    }

    private static func cString(from raw: UnsafeRawBufferPointer) -> String {
        let bytes = raw.bindMemory(to: UInt8.self)
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: UnsafeBufferPointer(rebasing: bytes[0..<end]), as: UTF8.self)
    }

    private static func machToNanos(_ ticks: UInt64) -> UInt64 {
        let (numer, denom) = timebase
        if numer == denom { return ticks }
        return ticks / denom &* numer + (ticks % denom) &* numer / denom
    }
}
