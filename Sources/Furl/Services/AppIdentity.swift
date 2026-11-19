import Foundation

/// The app's name on disk. Everything Furl stores lives in folders with this name.
/// (The app was called SweepMac before; `legacyFolderName` is only used to import that data once.)
enum AppIdentity {
    static var folderName: String {
        #if DEBUG
        // Update-test copies (debug builds only) keep their data apart from the real app's.
        if UpdateTestMode.isActive { return "Furl-UpdateTest" }
        #endif
        return "Furl"
    }
    static let legacyFolderName = "SweepMac"
    static let legacyBundleID = "com.sweepmac.utility"

    /// ~/Library/Application Support/Furl
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    /// ~/Library/Caches/Furl
    static var cachesDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent(folderName, isDirectory: true)
    }
}

#if DEBUG
/// Debug builds only (compiled out of release builds): a copy whose bundle id ends in ".updatetest"
/// runs the whole update flow against a local feed (`defaults write <id> FurlUpdateTestFeed
/// http://127.0.0.1:<port>/release.json`), keeps its data in "Furl-UpdateTest" folders and sends no
/// community stats, so testing never touches the real app or the public counter. See docs/releasing.md.
enum UpdateTestMode {
    static var isActive: Bool { Bundle.main.bundleIdentifier?.hasSuffix(".updatetest") == true }

    /// Only plain http on 127.0.0.1.
    static var feedURL: URL? {
        guard isActive, let raw = UserDefaults.standard.string(forKey: "FurlUpdateTestFeed"),
              let url = URL(string: raw), url.scheme == "http", url.host == "127.0.0.1" else { return nil }
        return url
    }

    /// NSLog plus a line in <support>/update-test.log, which the end-to-end test reads.
    static func log(_ message: String) {
        NSLog("Furl update test: %@", message)
        let file = AppIdentity.supportDirectory.appendingPathComponent("update-test.log")
        let line = Data("\(Date()) \(message)\n".utf8)
        try? FileManager.default.createDirectory(at: AppIdentity.supportDirectory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: file)
        }
    }
}
#endif
