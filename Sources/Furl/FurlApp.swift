import AppKit
import SwiftUI

/// Long-lived objects shared by the window, the menu bar extra, the scheduler and notifications.
@MainActor
enum AppServices {
    static let state = AppState()
    static let autoSweep = AutoSweepStore()
    static let compress = CompressStore()
    static var tray: CleanupTray { .shared }
    static var activity: ActivityLog { .shared }
    static let notifications = NotificationService.shared
    static let scheduler = AutoSweepScheduler(state: state, store: autoSweep, notifications: notifications)

    private static var started = false

    static func start() {
        guard !started else { return }
        started = true

        notifications.onReview = {
            AppWindows.showMain(section: .dashboard, state: state)
        }
        notifications.onOpenHistory = {
            AppWindows.showMain(section: .activity, state: state)
        }
        notifications.onUpdateAvailable = {
            AppWindows.showAbout(state: state)
        }
        notifications.onCleanNow = {
            Task { await confirmAndCleanFromNotification() }
        }
        notifications.onAskClean = {
            Task { await scheduler.approvePendingFromNotification() }
        }
        notifications.onAskReview = {
            Task { await scheduler.review() }
        }
        notifications.onUndoRun = { id in
            guard let run = autoSweep.history.first(where: { $0.id == id }), run.canUndo else {
                AppWindows.showMain(section: .activity, state: state)
                return
            }
            Task { await state.undoAutoSweepRun(run, store: autoSweep) }
        }
        notifications.onSwitchToAutomatic = {
            autoSweep.setMode(.automatic)
        }
        notifications.configure()
        ProcessesStore.shared.startBackgroundMonitoring()
        ProcessesIntegration.connect(to: autoSweep)
        ActivityLog.shared.connect(compress: compress)
        StatsLedger.shared.connect(compress: compress)
        #if DEBUG
        // Update-test copies must not add a fake install to the public counter.
        if !UpdateTestMode.isActive { CommunityStatsReporter.shared.start() }
        #else
        CommunityStatsReporter.shared.start()
        #endif
        SupportStore.shared.refreshCheckoutLink()
        UpdateChecker.shared.startAutomaticChecks()
        CleanupTray.shared.pruneMissing(state: state)
        InspectorStore.shared.connect(to: state)
        ErrorLog.shared.connect(to: state)
        ScanTimingRecorder.shared.connect(to: state)
        state.observeBrowsersForSafePlan()
        SnapshotsModel.connect()
        scheduler.start()

        // Dev check from the built bundle: open Furl.app --args -FurlTestNotification YES
        if UserDefaults.standard.bool(forKey: "FurlTestNotification") {
            Task {
                await notifications.postTest()
                NSLog("Furl test notification: authorization=%ld error=%@",
                      notifications.authorization.rawValue, notifications.lastError ?? "none")
            }
        }
    }

    /// "Clean now" on the low-disk notification: confirm in a regular alert, then clean safe items.
    private static func confirmAndCleanFromNotification() async {
        AppWindows.activateForWindow()
        // A settled, fresh scan: never a number from a scan that is still streaming in.
        let plan = await state.freshSafeCleanupPlan()
        let alert = NSAlert()
        if plan.isEmpty {
            alert.messageText = "Nothing safe to clean right now"
            alert.informativeText = "Open Furl to review larger items yourself."
            alert.addButton(withTitle: "Open Furl")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                AppWindows.showMain(section: .dashboard, state: state)
            }
            return
        }
        // Same number and items as the Overview's "Safe now" (GetSpaceBack board).
        alert.messageText = "Move \(FileSizeHelper.formatBytes(plan.bytes)) to the Trash?"
        alert.informativeText = "Furl’s “Safe now” items: caches, logs and junk rated Safe. You can undo this in Furl."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Exactly what the alert described, even if a scan finished while it was up.
        await state.cleanSafeItems(store: autoSweep, trigger: .notification, confirmedPaths: plan.paths)
    }
}

/// Opening, focusing and hiding Furl's windows, including from the menu bar and notifications.
@MainActor
enum AppWindows {
    private static var openMainWindow: (() -> Void)?

    static func registerOpenWindow(_ action: @escaping () -> Void) {
        openMainWindow = action
    }

    private static var openAboutWindow: (() -> Void)?

    static func registerOpenAbout(_ action: @escaping () -> Void) {
        openAboutWindow = action
    }

    /// About, from outside a view (the update notification). Falls back to the main window.
    static func showAbout(state: AppState) {
        activateForWindow()
        if let openAboutWindow { openAboutWindow() } else { showMain(section: nil, state: state) }
    }

    /// While running menu-bar-only the app has no Dock icon; give it one back before showing a window.
    static func activateForWindow() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func showMain(section: SidebarSection?, state: AppState) {
        if let section { state.selectedSection = section }
        activateForWindow()
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    static func showSettings() {
        activateForWindow()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }
    }

    /// Real app windows (not the status item or the menu bar popover).
    static var hasVisibleAppWindows: Bool {
        NSApp.windows.contains { window in
            window.isVisible && window.styleMask.contains(.titled) && window.canBecomeMain
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppServices.start()
            DockIcon.start()
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: nil, queue: .main
            ) { _ in
                // After the close finishes, drop the Dock icon if only the menu bar item is left.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    MainActor.assumeIsolated {
                        let store = AppServices.autoSweep
                        guard store.keepRunningInMenuBar, store.showMenuBarItem, !AppWindows.hasVisibleAppWindows else { return }
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated {
            let store = AppServices.autoSweep
            return !(store.keepRunningInMenuBar && store.showMenuBarItem)
        }
    }

    /// Clicking the Dock icon (or relaunching) while menu-bar-only brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainActor.assumeIsolated {
                AppWindows.showMain(section: nil, state: AppServices.state)
            }
        }
        return true
    }
}

@main
struct FurlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state: AppState
    @StateObject private var autoSweep: AutoSweepStore

    init() {
        PrivateStorage.prepare()
        _state = StateObject(wrappedValue: AppServices.state)
        _autoSweep = StateObject(wrappedValue: AppServices.autoSweep)
        // A Shortcuts run that launches Furl also comes through here and brings the window up. There
        // is no API that marks a launch as made for an App Intent: NSApplicationLaunchIsDefaultLaunchKey
        // is also false when windows are restored, and on macOS 14 the `Window` scene opens at launch
        // regardless (defaultLaunchBehavior is macOS 15+). Guessing wrong would hide the window on a
        // normal launch, so this stays as is until an intent launch can be tested end to end.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        Window("Furl", id: "main") {
            ContentView(state: state)
                .registersAboutOpener()
                .frame(minWidth: 980, minHeight: 640)
                .followsFurlPalette()
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            AboutCommands()
            CommandGroup(replacing: .newItem) {}

            CommandGroup(after: .undoRedo) {
                Button("Undo Last Cleanup") {
                    Task { await state.undoLastCleanup() }
                }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(state.lastUndo == nil || state.isCleaning)
            }

            CommandGroup(after: .textEditing) {
                Divider()
                Button("Find in Scan Results…") {
                    AppWindows.showMain(section: nil, state: state)
                    InspectorStore.shared.requestFind(state: state)
                }
                .keyboardShortcut("f", modifiers: [.command])
            }

            CommandMenu("Scan") {
                Button("Scan Everything") {
                    Task { await state.scanAll() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(state.isScanningAny)

                Button("Rescan Current Section") {
                    Task { await rescanCurrentSection() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(state.isScanningAny)

                Divider()

                Button("Also Scan Folder…") {
                    state.addExtraScanRoot()
                }
                .keyboardShortcut("o", modifiers: [.command])
            }

            CommandGroup(after: .sidebar) {
                Divider()
                // ⌘1…⌘9 only: there are more sections than digit keys.
                ForEach(Array(SidebarSection.allCases.prefix(9).enumerated()), id: \.element) { index, section in
                    Button(section.rawValue) {
                        state.selectedSection = section
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])
                }
            }
        }

        // SwiftUI writes `isInserted` back on every scene update. Writing the @Published property, even with
        // the same value, invalidates the scene again: an endless update loop (100% CPU, stack overflow in debug).
        MenuBarExtra(isInserted: Binding(
            get: { autoSweep.showMenuBarItem },
            set: { if autoSweep.showMenuBarItem != $0 { autoSweep.showMenuBarItem = $0 } }
        )) {
            MenuBarView(state: state, store: autoSweep)
                .followsFurlPalette()
        } label: {
            MenuBarLabel(state: state, store: autoSweep)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(state: state, autoSweep: autoSweep)
                .followsFurlPalette()
        }

        Window("About Furl", id: "about") {
            AboutWindowContent()
                .followsFurlPalette()
        }
        .windowResizability(.contentSize)
    }

    @MainActor
    private func rescanCurrentSection() async {
        switch state.selectedSection {
        case .dashboard: await state.scanAll()
        case .worktrees: await state.scanWorktrees()
        case .junk: await state.scanJunk()
        case .apps: await state.scanApps()
        case .largeFiles: await state.scanLargeFiles()
        // Same as Disk's Rescan button: What grew refreshes the home index, which saves a snapshot.
        case .disk: state.diskView == .grew ? await state.scanLargeFiles() : await state.scanSpace()
        case .duplicates: await state.scanDuplicates()
        case .smartReview: await state.scanSmartReview()
        case .processes: await ProcessesStore.shared.refresh()
        case .compress: await AppServices.compress.scan()
        case .activity: ActivityLog.shared.refreshRestorable()
        case .find: await state.scanAll()
        }
    }
}

/// App menu › About Furl opens our own About window; Check for Updates… opens it and starts the check.
/// Once a check has found a newer version the item reads "Update Available…" and opens About on it.
struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Furl") {
                openWindow(id: "about")
            }
            if updates.availableUpdate != nil {
                Button("Update Available…") {
                    AppWindows.activateForWindow()
                    openWindow(id: "about")
                }
            } else {
                Button("Check for Updates…") {
                    UpdateChecker.openAboutAndCheck(openWindow: openWindow)
                }
            }
        }

        // ReportProblem board: Help › Report a Problem…, Release Notes, Privacy (after Furl Help).
        CommandGroup(after: .help) {
            Button("Install Help") { NSWorkspace.shared.open(SupportConfig.installHelpURL) }
            Divider()
            Button("Report a Problem…") {
                AppWindows.registerOpenWindow { openWindow(id: "main") }
                ReportProblemStore.shared.present()
            }
            Button("Release Notes") { NSWorkspace.shared.open(SupportConfig.changelogURL) }
            Button("Privacy") { NSWorkspace.shared.open(SupportConfig.privacyURL) }
        }
    }
}

/// Registers `openWindow` so "Support" works even with the main window closed and no menu bar item.
private struct AboutWindowContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        AboutView(onSupport: {
            AppWindows.registerOpenWindow { openWindow(id: "main") }
            AppWindows.showMain(section: nil, state: AppServices.state)
            AppServices.state.showSupportSheet = true
        }, onReportProblem: {
            AppWindows.registerOpenWindow { openWindow(id: "main") }
            ReportProblemStore.shared.present()
        })
    }
}

/// Hands `openWindow(id: "about")` to `AppWindows`, so the update notification can open About.
private struct AboutOpenerRegistration: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear { AppWindows.registerOpenAbout { openWindow(id: "about") } }
    }
}

extension View {
    func registersAboutOpener() -> some View { modifier(AboutOpenerRegistration()) }
}
