import Foundation

/// A fresh folder under the temporary directory, removed when the value goes away.
final class TempDir {
    let path: String

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FurlTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // /var is a symlink to /private/var; git reports the resolved path.
        path = url.resolvingSymlinksInPath().path
    }

    func file(_ name: String) -> String { (path as NSString).appendingPathComponent(name) }

    func write(_ name: String, _ contents: String, executable: Bool = false) throws {
        try contents.write(toFile: file(name), atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file(name))
        }
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }
}
