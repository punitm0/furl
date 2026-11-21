import XCTest
@testable import Furl

final class OnboardingAccessTests: XCTestCase {
    private let off = AccessProbe(granted: false, grantedAfterReopen: false)
    private let on = AccessProbe(granted: true, grantedAfterReopen: false)
    private let afterReopen = AccessProbe(granted: false, grantedAfterReopen: true)

    private func next(_ current: AccessPhase, _ event: AccessEvent, _ probe: AccessProbe, opened: Bool = false) -> AccessPhase {
        AccessPhase.next(from: current, event: event, probe: probe, openedSettingsBefore: opened)
    }

    func testOpenSystemSettingsStartsWaiting() {
        XCTAssertEqual(next(.intro, .openedSettings, off), .waiting)
        XCTAssertEqual(next(.stillOff, .openedSettings, off), .waiting)
    }

    func testPollKeepsWaitingUntilGranted() {
        XCTAssertEqual(next(.waiting, .poll, off), .waiting)
        XCTAssertEqual(next(.waiting, .poll, on), .on)
        XCTAssertEqual(next(.stillOff, .poll, on), .on)
    }

    func testComingBackStillOffIsCalmState() {
        XCTAssertEqual(next(.waiting, .cameToFront, off), .stillOff)
        XCTAssertEqual(next(.stillOff, .cameToFront, off), .stillOff)
    }

    func testComingBackBeforeOpeningSettingsStaysOnSteps() {
        XCTAssertEqual(next(.intro, .cameToFront, off), .intro)
    }

    func testTurnedOnButNotYetEffectiveIsAlmostThere() {
        XCTAssertEqual(next(.waiting, .poll, afterReopen), .almostThere)
        XCTAssertEqual(next(.waiting, .cameToFront, afterReopen), .almostThere)
        XCTAssertEqual(next(.intro, .launched, afterReopen), .almostThere)
    }

    func testRelaunchAfterQuitAndReopenShowsOn() {
        XCTAssertEqual(next(.intro, .launched, on, opened: true), .on)
    }

    func testRelaunchWithoutAccess() {
        XCTAssertEqual(next(.intro, .launched, off, opened: true), .stillOff)
        XCTAssertEqual(next(.intro, .launched, off, opened: false), .intro)
    }

    func testOnlyWaitingAndStillOffPoll() {
        XCTAssertTrue(AccessPhase.waiting.polls)
        XCTAssertTrue(AccessPhase.stillOff.polls)
        XCTAssertFalse(AccessPhase.intro.polls)
        XCTAssertFalse(AccessPhase.on.polls)
        XCTAssertFalse(AccessPhase.almostThere.polls)
    }

    // MARK: Onboarding step persistence

    private func freshDefaults() -> UserDefaults {
        let name = "OnboardingAccessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @MainActor
    func testNewUserStartsOnWelcome() {
        let store = OnboardingStore(defaults: freshDefaults(), isExistingUser: { false })
        XCTAssertEqual(store.step, .welcome)
        XCTAssertTrue(store.isActive)
    }

    /// The copy that reopens from Applications has already run this version; it must still show Welcome.
    @MainActor
    func testWelcomeSurvivesRelaunchAfterMove() {
        let defaults = freshDefaults()
        _ = OnboardingStore(defaults: defaults, isExistingUser: { false })
        let reopened = OnboardingStore(defaults: defaults, isExistingUser: { true })
        XCTAssertEqual(reopened.step, .welcome)
        XCTAssertTrue(reopened.isActive)
    }

    @MainActor
    func testExistingUserSkipsOnboarding() {
        let defaults = freshDefaults()
        let store = OnboardingStore(defaults: defaults, isExistingUser: { true })
        XCTAssertEqual(store.step, .done)
        XCTAssertEqual(defaults.string(forKey: "onboarding.step"), "done")
    }

    @MainActor
    func testAccessStepSurvivesRelaunch() async {
        let defaults = freshDefaults()
        let first = OnboardingStore(defaults: defaults, isExistingUser: { false })
        await first.continueFromWelcome()
        XCTAssertEqual(first.step, .fullDiskAccess)
        first.stopChecking()
        let reopened = OnboardingStore(defaults: defaults, isExistingUser: { true })
        XCTAssertEqual(reopened.step, .fullDiskAccess)
    }

    @MainActor
    func testMoveToApplicationsHookCanHoldWelcome() async {
        let store = OnboardingStore(defaults: freshDefaults(), isExistingUser: { false })
        store.beforeAccessStep = { false }
        await store.continueFromWelcome()
        XCTAssertEqual(store.step, .welcome)
    }

    func testExistingUserDetection() {
        let defaults = freshDefaults()
        XCTAssertFalse(OnboardingStore.looksLikeExistingUser(defaults, previousRunVersion: nil))
        XCTAssertTrue(OnboardingStore.looksLikeExistingUser(defaults, previousRunVersion: "1.3.0"))
        defaults.set(["/tmp/x"], forKey: "discoveredProjectRoots")
        XCTAssertTrue(OnboardingStore.looksLikeExistingUser(defaults, previousRunVersion: nil))
    }

    // MARK: Limited-results line

    func testLimitedLineRules() {
        XCTAssertTrue(FullDiskAccess.showsLimitedLine(granted: false, dismissedForVersion: nil, currentVersion: "1.4.0", updateBannerShowing: false))
        XCTAssertFalse(FullDiskAccess.showsLimitedLine(granted: true, dismissedForVersion: nil, currentVersion: "1.4.0", updateBannerShowing: false))
        // Update banner wins.
        XCTAssertFalse(FullDiskAccess.showsLimitedLine(granted: false, dismissedForVersion: nil, currentVersion: "1.4.0", updateBannerShowing: true))
        // Hidden until the next version.
        XCTAssertFalse(FullDiskAccess.showsLimitedLine(granted: false, dismissedForVersion: "1.4.0", currentVersion: "1.4.0", updateBannerShowing: false))
        XCTAssertTrue(FullDiskAccess.showsLimitedLine(granted: false, dismissedForVersion: "1.4.0", currentVersion: "1.4.1", updateBannerShowing: false))
    }

    func testLimitedLineCopy() {
        XCTAssertEqual(LimitedResultsScreen.overview.buttonTitle, "Turn On Full Disk Access…")
        XCTAssertEqual(LimitedResultsScreen.junk.buttonTitle, "Turn On…")
        XCTAssertEqual(LimitedResultsScreen.largeFiles.message, LimitedResultsScreen.disk.message)
    }
}
