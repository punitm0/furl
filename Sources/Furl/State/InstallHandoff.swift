import AppKit
import os
import SwiftUI

/// InstallHandoff board: at launch, a Furl that runs from the disk image, from macOS's temporary copy
/// of a download or from any folder other than Applications offers to move itself. It copies itself,
/// opens the copy, quits, and the copy ejects the disk image. This happens before onboarding's Full
/// Disk Access step, because macOS ties that permission to where the app lives.
@MainActor
final class InstallHandoff: ObservableObject {
    static let shared = InstallHandoff()

    /// False until the launch check is finished: no offer needed, Not Now, Cancel, or a failure the
    /// user closed. Stays false while Furl moves itself (it then quits; the copy starts fresh).
    /// Onboarding waits for this before asking for Full Disk Access.
    @Published private(set) var isSettled = false
    /// The mint banner on the copy that just reopened from Applications, or nil.
    @Published private(set) var doneMessage: String? {
        didSet { scheduleDoneMessageHide() }
    }
    private var hideTask: Task<Void, Never>?

    private var started = false
    private var movingPanel: MovingPanelController?

    /// Launch arguments the old copy hands to the new one.
    enum Argument {
        static let movedFrom = "-FurlMovedFrom"
        static let parentPID = "-FurlMovedParentPID"
        static let ejectVolume = "-FurlMovedEjectVolume"
    }

    private var ourIdentifier: String { Bundle.main.bundleIdentifier ?? UpdateConfig.bundleIdentifier }
    private var ourVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func dismissDoneMessage() { doneMessage = nil }

    /// A one-time confirmation: it goes by itself 10 seconds after its last change (× is quicker).
    private func scheduleDoneMessageHide() {
        hideTask?.cancel()
        guard doneMessage != nil else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.doneMessage = nil
        }
    }

    /// Called once from `applicationDidFinishLaunching`.
    func runLaunchCheck() {
        guard !started else { return }
        started = true
        let place = InstallLocation.current()
        if place == .applications { finishMovedLaunch() }
        // Developers running build/Furl.app can opt out: defaults write app.getfurl.furl FurlSkipMoveCheck -bool YES
        var skip = UserDefaults.standard.bool(forKey: "FurlSkipMoveCheck")
        #if DEBUG
        // Update-test copies skip it unless a scratch Applications folder is set (docs/releasing.md).
        if UpdateTestMode.isActive { skip = UserDefaults.standard.string(forKey: "FurlMoveTestApplications") == nil }
        #endif
        guard place.offersMove, !skip else { settle(); return }
        // One turn later, so the alert comes up over a finished launch rather than in the middle of it.
        DispatchQueue.main.async { [self] in offer(place) }
    }

    private func settle() { isSettled = true }

    // MARK: - Offer

    private func offer(_ place: InstallLocation.Place) {
        let alert = NSAlert()
        alert.messageText = "Move Furl to Applications?"
        switch place {
        case .diskImage:
            alert.informativeText = "Furl is running from the disk image. In Applications it keeps working after you eject, and macOS remembers its permissions.\n\nFurl copies itself, reopens from Applications and ejects the disk image."
        case .translocated(let original):
            let folder = original.map { FileManager.default.displayName(atPath: $0.deletingLastPathComponent().path) } ?? "Downloads"
            alert.informativeText = "Furl is running from a temporary copy that macOS made of the download. Settings and permissions won’t stick there.\n\nThe download in your \(folder) folder stays where it is. Move it to the Trash when you like."
        case .otherFolder(let folder):
            let name = FileManager.default.displayName(atPath: folder.path)
            alert.informativeText = "Furl is running from your \(name) folder. In Applications it’s easy to find, and macOS remembers its permissions.\n\nFurl copies itself and reopens from Applications. The copy in \(name) stays where it is. Move it to the Trash when you like."
        case .applications, .notAnApp:
            settle()
            return
        }
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        AppWindows.activateForWindow()
        // "Not Now" never blocks; Furl asks again next time it opens from outside Applications.
        guard alert.runModal() == .alertFirstButtonReturn else { settle(); return }
        moveOrResolveExisting(place)
    }

    // MARK: - A copy already there

    private func moveOrResolveExisting(_ place: InstallLocation.Place) {
        let destinations = InstallLocation.destinations()
        let system = destinations[0]
        let systemFacts = InstallLocation.bundleFacts(at: system)
        if systemFacts.exists {
            let existing = InstallLocation.compareExisting(
                identifier: systemFacts.identifier, version: systemFacts.version, isDirectory: systemFacts.isDirectory,
                ourIdentifier: ourIdentifier, ourVersion: ourVersion)
            if existing == .notFurl {
                showFailure("Something else named Furl is already in Applications. Rename or move it in Finder, then try again. Nothing was changed.")
                return
            }
            resolveExisting(existing, at: system, place: place)
            return
        }
        // A Furl the user keeps in ~/Applications is the one to update or open.
        let user = destinations[1]
        let userFacts = InstallLocation.bundleFacts(at: user)
        if userFacts.exists {
            let existing = InstallLocation.compareExisting(
                identifier: userFacts.identifier, version: userFacts.version, isDirectory: userFacts.isDirectory,
                ourIdentifier: ourIdentifier, ourVersion: ourVersion)
            if existing != .notFurl {
                resolveExisting(existing, at: user, place: place)
                return
            }
        }
        startMove(place, to: system, replacing: .none)
    }

    private func resolveExisting(_ existing: InstallLocation.Existing, at url: URL, place: InstallLocation.Place) {
        let isRunning = NSRunningApplication.runningApplications(withBundleIdentifier: ourIdentifier)
            .contains { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Furl is already in Applications"
        var canReplace = false
        switch existing {
        case .older(let version) where !isRunning:
            canReplace = true
            alert.informativeText = "Applications has Furl \(version). This one is \(ourVersion). Replace moves Furl \(version) to the Trash first. Its settings and History stay."
        case .older(let version):
            alert.informativeText = "Applications has Furl \(version), and it’s open. Quit it to replace it with \(ourVersion), or keep using it."
        case .sameOrNewer(let version):
            let newer = UpdateChecker.isNewer(version, than: ourVersion)
            alert.informativeText = newer
                ? "Applications has Furl \(version), which is newer than this one (\(ourVersion)). Open that one instead."
                : "Applications already has this version of Furl. Open that one instead."
        case .none, .notFurl:
            startMove(place, to: url, replacing: existing)
            return
        }
        if canReplace { alert.addButton(withTitle: "Replace It") }
        alert.addButton(withTitle: "Open the One in Applications")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        let offset = canReplace ? 0 : 1
        switch response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + offset {
        case 0: startMove(place, to: url, replacing: existing)
        case 1: open(url, place: place, isMove: false)
        default: settle()
        }
    }

    // MARK: - Move

    private func startMove(_ place: InstallLocation.Place, to destination: URL, replacing: InstallLocation.Existing) {
        let panel = MovingPanelController()
        movingPanel = panel
        panel.show()
        let source = Bundle.main.bundleURL
        let identifier = ourIdentifier
        let version = ourVersion
        Task.detached(priority: .userInitiated) {
            let failure: AppMover.Failure?
            do {
                try AppMover.copy(source, to: destination, replacing: replacing, ourIdentifier: identifier,
                                  ourVersion: version) { fraction in
                    Task { @MainActor in panel.model.fraction = fraction }
                }
                failure = nil
            } catch let error as AppMover.Failure {
                failure = error
            } catch {
                failure = AppMover.Failure(kind: .other, message: "Furl couldn’t be moved. Nothing was changed.")
            }
            await MainActor.run {
                if let failure {
                    self.closePanel()
                    self.showFailure(failure.message)
                } else {
                    self.open(destination, place: place, isMove: true)
                }
            }
        }
    }

    /// Opens the copy in Applications, then quits. The copy ejects the disk image once this one is gone.
    private func open(_ url: URL, place: InstallLocation.Place, isMove: Bool) {
        // The copy in Applications is already open: bring it forward and step aside.
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: ourIdentifier)
            .first(where: { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }) {
            running.activate()
            NSApp.terminate(nil)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // Same bundle id as this running copy: without this, macOS would just bring this one forward.
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        var kind = "folder"
        var eject: [String] = []
        switch place {
        case .diskImage(let volume):
            kind = "diskImage"
            eject = [Argument.ejectVolume, volume.path]
        case .translocated: kind = "translocated"
        default: break
        }
        // "Open the One in Applications" isn't a move: no banner there, but the disk image still ejects.
        configuration.arguments = [Argument.parentPID, String(ProcessInfo.processInfo.processIdentifier),
                                   Argument.movedFrom, isMove ? kind : "opened"] + eject
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            Task { @MainActor in
                if error != nil {
                    self.closePanel()
                    self.showFailure("Furl is in Applications, but it couldn’t be opened from there. Open it from Applications in Finder.")
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func closePanel() {
        movingPanel?.close()
        movingPanel = nil
    }

    // MARK: - Failed

    private func showFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Furl couldn’t be moved"
        alert.informativeText = message
        alert.addButton(withTitle: "Show Applications Folder")
        alert.addButton(withTitle: "Keep Using It From Here")
        AppWindows.activateForWindow()
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
        }
        settle()
    }

    // MARK: - The reopened copy

    /// Runs in the copy that the old one opened: shows the banner and ejects the disk image once the
    /// old copy has quit. Launch arguments can come from anyone, so the volume is checked first.
    private func finishMovedLaunch() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let from = Self.value(after: Argument.movedFrom, in: arguments) else { return }
        let showsBanner = from != "opened"
        if showsBanner { doneMessage = "Furl is in Applications now." }
        guard from == "diskImage" || from == "opened",
              let volume = Self.value(after: Argument.ejectVolume, in: arguments) else { return }
        let parent = Self.value(after: Argument.parentPID, in: arguments).flatMap { Int32($0) }
        let identifier = ourIdentifier
        Task.detached(priority: .utility) {
            if let parent, parent != getpid() { Self.waitForExit(of: parent, timeout: 10) }
            guard let mount = Self.ejectableFurlVolume(volume, identifier: identifier) else { return }
            // macOS's privacy service (tccd) keeps the old copy's binary open for half a minute or so
            // after it quits, and Finder or Spotlight may still be reading it; keep trying for a while.
            var ejected = false
            var attempt = 0
            let deadline = Date().addingTimeInterval(90)
            while !ejected, Date() < deadline {
                if attempt > 0 { try? await Task.sleep(for: .seconds(3)) }
                attempt += 1
                guard Self.ejectableFurlVolume(volume, identifier: identifier) != nil else { break }
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: mount)
                    ejected = true
                } catch {
                    Logger(subsystem: "app.getfurl.furl", category: "install")
                        .info("eject attempt \(attempt) failed: \(String(describing: error), privacy: .public)")
                }
            }
            guard ejected, showsBanner else { return }
            await MainActor.run {
                if self.doneMessage != nil {
                    self.doneMessage = "Furl is in Applications now, and the disk image is ejected."
                }
            }
        }
    }

    nonisolated static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    nonisolated private static func waitForExit(of pid: Int32, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while kill(pid, 0) == 0, Date() < deadline { usleep(100_000) }
    }

    /// Only a read-only, ejectable volume mounted under /Volumes whose top level holds our Furl.app.
    nonisolated static func ejectableFurlVolume(_ path: String, identifier: String) -> URL? {
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard url.path.hasPrefix("/Volumes/"), url.pathComponents.count == 3,
              let facts = InstallLocation.volumeFacts(for: url.path),
              facts.mountPoint.standardizedFileURL.path == url.path, facts.isReadOnly, facts.isEjectable, facts.isDiskImage,
              InstallLocation.bundleFacts(at: url.appendingPathComponent(InstallLocation.bundleName)).identifier == identifier
        else { return nil }
        return url
    }
}

// MARK: - Moving panel

/// "Moving Furl to Applications…" with a progress bar (board: Moving). An alert-shaped panel with no
/// buttons: once the copy starts, the next thing that happens is Furl reopening.
@MainActor
private final class MovingPanelController {
    final class Model: ObservableObject {
        @Published var fraction: Double = 0
    }

    let model = Model()
    private var panel: NSPanel?

    func show() {
        let hosting = NSHostingView(rootView: MovingView(model: model).followsFurlPalette())
        hosting.frame.size = hosting.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .modalPanel
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.center()
        AppWindows.activateForWindow()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

private struct MovingView: View {
    @ObservedObject var model: MovingPanelController.Model

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            Text("Moving Furl to Applications…")
                .font(.system(size: 13, weight: .bold))
                .padding(.top, 4)
            Text("Furl will reopen by itself in a moment.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.sweep.opacity(0.25))
                    Capsule().fill(Theme.sweep).frame(width: geo.size.width * model.fraction)
                }
            }
            .frame(height: 6)
            .padding(.top, 6)
            .animation(.linear(duration: 0.2), value: model.fraction)
            Text("Copying · \(Int((model.fraction * 100).rounded()))%")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .multilineTextAlignment(.center)
        .padding(EdgeInsets(top: 20, leading: 16, bottom: 16, trailing: 16))
        .frame(width: 272)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Done banner

/// "Furl is in Applications now, and the disk image is ejected." Mint banner on the reopened app
/// (board: Done). Renders nothing when there's nothing to say.
struct InstallDoneBanner: View {
    @ObservedObject private var handoff = InstallHandoff.shared

    var body: some View {
        if let message = handoff.doneMessage {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.sweepDeep)
                Text(message)
                    .foregroundStyle(Theme.sweepDeep)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    handoff.dismissDoneMessage()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.sweepDeep)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .font(.system(size: 13))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(Theme.mintTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }
}
