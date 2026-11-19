import Foundation

/// Saves and loads a `FileIndex` as one compact binary file (raw record arrays + name bytes) in
/// `~/Library/Application Support/Furl/ScanIndex/`. No third-party dependencies, no network.
///
/// Format (little-endian, host layout — the file is a cache, so a different build simply rebuilds it):
///   Header | rootPath UTF-8 | fseventsUUID UTF-8 | DirRecord × dirCount | FileRecord × fileCount | names
struct IndexStore: Sendable {
    let directory: URL

    static let formatVersion: UInt32 = 1
    private static let magic: UInt32 = 0x5857_4958 // "XIWX"

    private struct Header {
        var magic: UInt32
        var version: UInt32
        var dirStride: UInt32
        var fileStride: UInt32
        var dirCount: UInt64
        var fileCount: UInt64
        var nameBytes: UInt64
        var eventID: UInt64
        var configHash: UInt64
        var builtAt: Double
        var rootPathBytes: UInt32
        var uuidBytes: UInt32
    }

    static var defaultDirectory: URL {
        return AppIdentity.supportDirectory.appendingPathComponent("ScanIndex", isDirectory: true)
    }

    init(directory: URL = IndexStore.defaultDirectory) {
        self.directory = directory
    }

    func fileURL(forRoot root: String) -> URL {
        var h = FNV1a()
        h.add(root)
        return directory.appendingPathComponent(String(format: "%016llx.sweepindex", h.value))
    }

    func save(_ index: FileIndex) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = Array(index.rootPath.utf8)
        let uuid = Array(index.fseventsUUID.utf8)
        var header = Header(
            magic: Self.magic, version: Self.formatVersion,
            dirStride: UInt32(MemoryLayout<DirRecord>.stride), fileStride: UInt32(MemoryLayout<FileRecord>.stride),
            dirCount: UInt64(index.dirs.count), fileCount: UInt64(index.files.count), nameBytes: UInt64(index.names.count),
            eventID: index.eventID, configHash: index.configHash, builtAt: index.builtAt.timeIntervalSince1970,
            rootPathBytes: UInt32(root.count), uuidBytes: UInt32(uuid.count)
        )
        var data = Data(capacity: MemoryLayout<Header>.size + root.count + uuid.count
            + index.dirs.count * MemoryLayout<DirRecord>.stride
            + index.files.count * MemoryLayout<FileRecord>.stride + index.names.count)
        withUnsafeBytes(of: &header) { data.append(contentsOf: $0) }
        data.append(contentsOf: root)
        data.append(contentsOf: uuid)
        index.dirs.withUnsafeBytes { data.append(contentsOf: $0) }
        index.files.withUnsafeBytes { data.append(contentsOf: $0) }
        data.append(contentsOf: index.names)
        try data.write(to: fileURL(forRoot: index.rootPath), options: [.atomic])
    }

    /// Nil when there is no index, it is corrupt, or it was written by an incompatible build.
    func load(root: String) -> FileIndex? {
        guard let data = try? Data(contentsOf: fileURL(forRoot: root), options: [.alwaysMapped]) else { return nil }
        return data.withUnsafeBytes { raw -> FileIndex? in
            let headerSize = MemoryLayout<Header>.size
            guard raw.count >= headerSize else { return nil }
            let header = raw.loadUnaligned(as: Header.self)
            guard header.magic == Self.magic, header.version == Self.formatVersion,
                  header.dirStride == UInt32(MemoryLayout<DirRecord>.stride),
                  header.fileStride == UInt32(MemoryLayout<FileRecord>.stride) else { return nil }

            let dirBytes = Int(header.dirCount) * MemoryLayout<DirRecord>.stride
            let fileBytes = Int(header.fileCount) * MemoryLayout<FileRecord>.stride
            let expected = headerSize + Int(header.rootPathBytes) + Int(header.uuidBytes) + dirBytes + fileBytes + Int(header.nameBytes)
            guard raw.count == expected, header.dirCount > 0 else { return nil }

            var offset = headerSize
            let rootPath = String(decoding: UnsafeRawBufferPointer(rebasing: raw[offset..<offset + Int(header.rootPathBytes)]), as: UTF8.self)
            offset += Int(header.rootPathBytes)
            guard rootPath == root else { return nil }
            let uuid = String(decoding: UnsafeRawBufferPointer(rebasing: raw[offset..<offset + Int(header.uuidBytes)]), as: UTF8.self)
            offset += Int(header.uuidBytes)

            let dirs = [DirRecord](unsafeUninitializedCapacity: Int(header.dirCount)) { buffer, count in
                UnsafeMutableRawBufferPointer(buffer).copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[offset..<offset + dirBytes]))
                count = Int(header.dirCount)
            }
            offset += dirBytes
            let files = [FileRecord](unsafeUninitializedCapacity: Int(header.fileCount)) { buffer, count in
                UnsafeMutableRawBufferPointer(buffer).copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[offset..<offset + fileBytes]))
                count = Int(header.fileCount)
            }
            offset += fileBytes
            let names = [UInt8](UnsafeRawBufferPointer(rebasing: raw[offset..<offset + Int(header.nameBytes)]))

            // Cheap structural validation so a damaged file can't crash later lookups.
            for (id, dir) in dirs.enumerated() {
                guard dir.parent < Int32(id), Int(dir.name.offset) + Int(dir.name.length) <= names.count else { return nil }
            }
            var previousDir: Int32 = 0
            for file in files {
                guard file.dir >= previousDir, Int(file.dir) < dirs.count,
                      Int(file.name.offset) + Int(file.name.length) <= names.count else { return nil }
                previousDir = file.dir
            }
            return FileIndex(
                rootPath: rootPath, dirs: dirs, files: files, names: names,
                eventID: header.eventID, fseventsUUID: uuid,
                builtAt: Date(timeIntervalSince1970: header.builtAt), configHash: header.configHash
            )
        }
    }

    func remove(root: String) {
        try? FileManager.default.removeItem(at: fileURL(forRoot: root))
    }
}
