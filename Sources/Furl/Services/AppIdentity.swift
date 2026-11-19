import Foundation

/// The app's name on disk. Everything Furl stores lives in folders with this name.
/// (The app was called SweepMac before; `legacyFolderName` is only used to import that data once.)
enum AppIdentity {
    static let folderName = "Furl"
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
