import AppKit
import Foundation

/// First run, per the WelcomeAccess board: Welcome, then Full Disk Access, then the Overview.
///
/// The step is saved so that when macOS quits and reopens Furl after Full Disk Access is turned
/// on, Furl comes back on the Full Disk Access step ("Full Disk Access is on"), not on Welcome.
@MainActor
final class OnboardingStore: ObservableObject {
    static let shared = OnboardingStore()

    enum Step: String {
        case welcome
        case fullDiskAccess
        case done
    }

    private enum Keys {
        static let step = "onboarding.step"
        static let openedSettings = "onboarding.openedSettings"
    }

    @Published private(set) var step: Step
    @Published private(set) var access: AccessPhase = .intro

    /// Hook for the move-to-Applications check (install-handoff). Welcome's Continue awaits it
    /// before showing the Full Disk Access step, because macOS grants access to one copy of the app
    /// and that should be the one in Applications. Return false to stay on Welcome (for example
    /// when Furl is about to quit and reopen from Applications).
    var beforeAccessStep: (@MainActor () async -> Bool)?

    private let defaults: UserDefaults
    private var pollTask: Task<Void, Never>?
    private var openedSettings: Bool {
        didSet { defaults.set(openedSettings, forKey: Keys.openedSettings) }
    }

    init(defaults: UserDefaults = .standard, isExistingUser: (() -> Bool)? = nil) {
        self.defaults = defaults
        openedSettings = defaults.bool(forKey: Keys.openedSettings)
        if let saved = defaults.string(forKey: Keys.step).flatMap(Step.init(rawValue:)) {
            step = saved
        } else if isExistingUser?() ?? Self.looksLikeExistingUser(defaults, previousRunVersion: FullDiskAccess.shared.previousRunVersion) {
            // People updating from 1.3 or earlier already know Furl; the update banner covers access.
            step = .done
            defaults.set(Step.done.rawValue, forKey: Keys.step)
        } else {
            step = .welcome
            // Saved now: the copy that reopens from Applications (or after a quit) has already run
            // this version, and would otherwise be taken for an existing user and skip Welcome.
            defaults.set(Step.welcome.rawValue, forKey: Keys.step)
        }
    }

    var isActive: Bool { step != .done }

    /// Anything an earlier version saved: the last version that ran, projects found by a scan,
    /// or space freed.
    nonisolated static func looksLikeExistingUser(_ defaults: UserDefaults, previousRunVersion: String?) -> Bool {
        previousRunVersion != nil
            || defaults.object(forKey: "discoveredProjectRoots") != nil
            || defaults.object(forKey: "deletionMode") != nil
    }

    // MARK: Steps

    func continueFromWelcome() async {
        if let beforeAccessStep, !(await beforeAccessStep()) { return }
        set(.fullDiskAccess)
        enterAccessStep()
    }

    /// Called when the window appears; resumes the access step after a relaunch.
    func resume() {
        if step == .fullDiskAccess { enterAccessStep() }
    }

    func finish() {
        stopChecking()
        set(.done)
    }

    func stopChecking() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func set(_ new: Step) {
        step = new
        defaults.set(new.rawValue, forKey: Keys.step)
    }

    // MARK: Full Disk Access

    func openSystemSettings() {
        openedSettings = true
        DeletionService.openFullDiskAccessSettings()
        Task { await apply(.openedSettings) }
    }

    /// Furl came back to the front.
    func appBecameActive() {
        guard step == .fullDiskAccess else { return }
        Task { await apply(.cameToFront) }
    }

    /// "Almost there": quit and open this copy of Furl again so macOS applies the access.
    func reopenFurl() {
        if UpdateInstaller.relaunch(appURL: Bundle.main.bundleURL) {
            NSApp.terminate(nil)
        }
    }

    private func enterAccessStep() {
        Task { await apply(.launched) }
        startPolling()
    }

    /// Every ~3 s while on the access step, so "Full Disk Access is on" shows as soon as macOS
    /// lets Furl read, even while System Settings is in front.
    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled, self.step == .fullDiskAccess else { return }
                if self.access.polls { await self.apply(.poll) }
            }
        }
    }

    private func apply(_ event: AccessEvent) async {
        let probe = await AccessProbe.current()
        guard step == .fullDiskAccess else { return }
        let next = AccessPhase.next(from: access, event: event, probe: probe, openedSettingsBefore: openedSettings)
        if next != access { access = next }
        if next == .on { FullDiskAccess.shared.refresh() }
    }
}

/// What the Full Disk Access step shows (WelcomeAccess board).
enum AccessPhase: Equatable, Sendable {
    /// The three steps, Open System Settings, Continue Without It.
    case intro
    /// Right after Open System Settings: "Waiting for Full Disk Access".
    case waiting
    /// "Full Disk Access is on".
    case on
    /// Turned on in System Settings but macOS applies it only once Furl reopens.
    case almostThere
    /// Came back to Furl and the check still fails. Calm, not an error.
    case stillOff

    /// States that keep checking every few seconds.
    var polls: Bool { self == .waiting || self == .stillOff }

    static func next(from current: AccessPhase, event: AccessEvent, probe: AccessProbe, openedSettingsBefore: Bool) -> AccessPhase {
        if probe.granted { return .on }
        if probe.grantedAfterReopen { return .almostThere }
        switch event {
        case .openedSettings:
            return .waiting
        case .poll:
            return current
        case .cameToFront:
            return current == .intro ? .intro : .stillOff
        case .launched:
            return openedSettingsBefore ? .stillOff : .intro
        }
    }
}

enum AccessEvent: Sendable {
    case openedSettings
    case poll
    case cameToFront
    case launched
}

/// One reading of Full Disk Access.
struct AccessProbe: Equatable, Sendable {
    /// This process can read protected files now.
    var granted: Bool
    /// This process can't, but a freshly started one can: access is turned on in System Settings
    /// and macOS applies it to Furl once it reopens.
    var grantedAfterReopen: Bool

    static func current() async -> AccessProbe {
        await Task.detached(priority: .utility) {
            if FullDiskAccess.checkAccess() {
                return AccessProbe(granted: true, grantedAfterReopen: false)
            }
            return AccessProbe(granted: false, grantedAfterReopen: FullDiskAccess.checkAccessInNewProcess())
        }.value
    }
}
