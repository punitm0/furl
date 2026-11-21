import CoreServices
import Foundation

/// Watches ~/.Trash with FSEvents while Furl runs and reports each .app that lands there
/// (LeftoversWhatsNew board). Nothing runs once Furl quits. Apps already in the Trash when it
/// starts are never reported. Without Full Disk Access the Trash can't be listed, so nothing is.
final class TrashWatcher: @unchecked Sendable {
    /// Called on the main queue with the URL of an app that just landed in the Trash.
    private let onNewApp: @Sendable (URL) -> Void
    private let trashURL: URL
    /// All state below is touched only on this queue.
    private let queue = DispatchQueue(label: "app.getfurl.trash-watcher")
    private var stream: FSEventStreamRef?
    /// Top-level .app names seen in the Trash; nil until the Trash could be listed once.
    private var known: Set<String>?

    init(trashURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"),
         onNewApp: @escaping @Sendable (URL) -> Void) {
        self.trashURL = trashURL
        self.onNewApp = onNewApp
    }

    func start() {
        queue.async { [self] in
            guard stream == nil else { return }
            known = listApps()
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<TrashWatcher>.fromOpaque(info).takeUnretainedValue().trashChanged()
            }
            guard let created = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context, [trashURL.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
            ) else { return }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                return
            }
            stream = created
        }
    }

    func stop() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    /// Runs on `queue`.
    private func trashChanged() {
        guard let current = listApps() else { return }
        defer { known = current }
        // The first successful listing (e.g. after Full Disk Access was granted) only sets the baseline.
        guard let known else { return }
        let added = Self.newApps(previous: known, current: current)
        guard !added.isEmpty else { return }
        let urls = added.map { trashURL.appendingPathComponent($0, isDirectory: true) }
        let handler = onNewApp
        DispatchQueue.main.async {
            for url in urls { handler(url) }
        }
    }

    /// Names of top-level .app entries, or nil when the Trash can't be listed.
    private func listApps() -> Set<String>? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: trashURL.path) else { return nil }
        return Set(names.filter { ($0 as NSString).pathExtension.lowercased() == "app" })
    }

    static func newApps(previous: Set<String>, current: Set<String>) -> [String] {
        current.subtracting(previous).sorted()
    }
}
