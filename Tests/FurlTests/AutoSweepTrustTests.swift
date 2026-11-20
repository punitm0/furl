import XCTest
@testable import Furl

/// AutoSweepTrust: the Off / Ask first / Automatic migration, the Permanent Trash rule's migration,
/// the approval count that offers Automatic once, and the Overview suggestion.
@MainActor
final class AutoSweepTrustTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "FurlTests.AutoSweepTrust.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: Mode migration

    func testNewUserStartsOffWithPermanentRuleUnticked() {
        let result = AutoSweepStore.migrateTrustSettings(defaults)
        XCTAssertEqual(result.mode, .off)
        XCTAssertFalse(result.expireTrash)
        XCTAssertEqual(defaults.string(forKey: "autoSweep.mode"), "off")
        XCTAssertEqual(defaults.object(forKey: "autoSweep.trash.enabled") as? Bool, false)
    }

    func testUserWhoHadAutoSweepOnMovesToAutomaticAndKeepsTrashExpiry() {
        defaults.set(true, forKey: "autoSweep.enabled")
        let result = AutoSweepStore.migrateTrustSettings(defaults)
        XCTAssertEqual(result.mode, .automatic, "Their runs keep happening by themselves")
        XCTAssertTrue(result.expireTrash, "They relied on the old default, which was on")
        XCTAssertEqual(defaults.string(forKey: "autoSweep.mode"), "automatic")
    }

    func testUserWhoHadAutoSweepOffStaysOff() {
        defaults.set(false, forKey: "autoSweep.enabled")
        let result = AutoSweepStore.migrateTrustSettings(defaults)
        XCTAssertEqual(result.mode, .off)
        XCTAssertFalse(result.expireTrash, "It never ran for them, so unticking changes nothing")
    }

    func testExplicitTrashChoiceIsKept() {
        defaults.set(true, forKey: "autoSweep.enabled")
        defaults.set(false, forKey: "autoSweep.trash.enabled")
        XCTAssertFalse(AutoSweepStore.migrateTrustSettings(defaults).expireTrash)

        let other = UserDefaults(suiteName: suiteName + ".b")!
        defer { other.removePersistentDomain(forName: suiteName + ".b") }
        other.set(false, forKey: "autoSweep.enabled")
        other.set(true, forKey: "autoSweep.trash.enabled")
        XCTAssertTrue(AutoSweepStore.migrateTrustSettings(other).expireTrash)
    }

    func testSavedModeWinsOverLegacySwitchAndMigrationRunsOnce() {
        defaults.set(true, forKey: "autoSweep.enabled")
        XCTAssertEqual(AutoSweepStore.migrateTrustSettings(defaults).mode, .automatic)
        // The user picks Ask first later; the legacy key must not pull them back to Automatic.
        defaults.set("askFirst", forKey: "autoSweep.mode")
        defaults.set(false, forKey: "autoSweep.enabled")
        XCTAssertEqual(AutoSweepStore.migrateTrustSettings(defaults).mode, .askFirst)
    }

    func testPureMigrationTable() {
        XCTAssertEqual(AutoSweepMigration.mode(stored: nil, legacyEnabled: nil), .off)
        XCTAssertEqual(AutoSweepMigration.mode(stored: nil, legacyEnabled: true), .automatic)
        XCTAssertEqual(AutoSweepMigration.mode(stored: "garbage", legacyEnabled: false), .off)
        XCTAssertEqual(AutoSweepMigration.mode(stored: "askFirst", legacyEnabled: true), .askFirst)
        XCTAssertEqual(AutoSweepMigration.mode(stored: "askFirst", legacyEnabled: false), .askFirst)
        XCTAssertEqual(AutoSweepMigration.mode(stored: "automatic", legacyEnabled: true), .automatic)
        XCTAssertEqual(AutoSweepMigration.mode(stored: "automatic", legacyEnabled: false), .off,
                       "An older build turned it off after a downgrade")
        XCTAssertFalse(AutoSweepMigration.expireTrash(stored: nil, legacyEnabled: nil))
        XCTAssertTrue(AutoSweepMigration.expireTrash(stored: nil, legacyEnabled: true))
    }

    func testOffAfterDowngradeIsSaved() {
        defaults.set(true, forKey: "autoSweep.enabled")
        XCTAssertEqual(AutoSweepStore.migrateTrustSettings(defaults).mode, .automatic)
        // An older build only knows the switch and turns it off.
        defaults.set(false, forKey: "autoSweep.enabled")
        XCTAssertEqual(AutoSweepStore.migrateTrustSettings(defaults).mode, .off)
        XCTAssertEqual(defaults.string(forKey: "autoSweep.mode"), "off")
    }

    // MARK: Approval count

    func testThirdApprovalWithoutChangesOffersAutomaticOnce() {
        var ladder = AutoSweepTrustLadder()
        XCTAssertFalse(ladder.recordApproval(changed: false))
        XCTAssertFalse(ladder.recordApproval(changed: false))
        XCTAssertTrue(ladder.recordApproval(changed: false))
        ladder.markOffered()
        XCTAssertTrue(ladder.offeredAutomatic)
        // "Keep asking": it keeps asking and never offers again.
        for _ in 0..<5 { XCTAssertFalse(ladder.recordApproval(changed: false)) }
    }

    func testOfferThatCouldNotBeShownIsTriedAgain() {
        var ladder = AutoSweepTrustLadder()
        _ = ladder.recordApproval(changed: false)
        _ = ladder.recordApproval(changed: false)
        XCTAssertTrue(ladder.recordApproval(changed: false))
        // Notifications were off, so markOffered() wasn't called.
        XCTAssertFalse(ladder.offeredAutomatic)
        XCTAssertTrue(ladder.recordApproval(changed: false))
    }

    // MARK: Approving an old ask

    private let day: TimeInterval = 86_400
    private func rules(caches: Bool = true, cacheDays: Int = 30, trash: Bool = true, trashDays: Int = 30,
                       processes: Bool = true, downloads: Bool = true) -> AutoSweepRules {
        AutoSweepRules(cachesEnabled: caches, cachesUnusedDays: cacheDays, stopProcessesEnabled: processes,
                       expireTrashEnabled: trash, expireTrashDays: trashDays, tidyDownloadsEnabled: downloads)
    }

    private func nodeModules(modifiedDaysAgo: Double, now: Date) -> AutoSweepPreview.Item {
        .init(kind: .dependency, path: "/code/web/node_modules", name: "web/node_modules", bytes: 10,
              project: "/code/web", modified: now.addingTimeInterval(-modifiedDaysAgo * day))
    }

    func testDependencyInAProjectUsedSinceTheAskIsKept() {
        let now = Date()
        let item = nodeModules(modifiedDaysAgo: 50, now: now)
        // Sunday's ask: project untouched for 45 days.
        XCTAssertTrue(AutoSweepApproval.stillAllowed(item, rules: rules(), now: now) { _ in now.addingTimeInterval(-45 * self.day) })
        // The user edited it Tuesday; Clean on Wednesday must leave it alone.
        XCTAssertFalse(AutoSweepApproval.stillAllowed(item, rules: rules(), now: now) { _ in now.addingTimeInterval(-1 * self.day) })
        // Unsure about the project (huge folder): skip.
        XCTAssertFalse(AutoSweepApproval.stillAllowed(item, rules: rules(), now: now) { _ in .distantFuture })
    }

    func testStricterRuleSinceTheAskIsFollowed() {
        let now = Date()
        let item = nodeModules(modifiedDaysAgo: 40, now: now)
        let idle: (String) -> Date = { _ in now.addingTimeInterval(-40 * self.day) }
        XCTAssertTrue(AutoSweepApproval.stillAllowed(item, rules: rules(cacheDays: 30), now: now, projectActivity: idle))
        XCTAssertFalse(AutoSweepApproval.stillAllowed(item, rules: rules(cacheDays: 60), now: now, projectActivity: idle))
        XCTAssertFalse(AutoSweepApproval.stillAllowed(item, rules: rules(caches: false), now: now, projectActivity: idle))

        let cache = AutoSweepPreview.Item(kind: .cache, path: "/Library/Caches/pnpm", name: "pnpm", bytes: 10)
        XCTAssertTrue(AutoSweepApproval.stillAllowed(cache, rules: rules(cacheDays: 365), now: now) { _ in .distantFuture })
        XCTAssertFalse(AutoSweepApproval.stillAllowed(cache, rules: rules(caches: false), now: now) { _ in .distantPast })
    }

    func testTrashEntryMustStillBeOldEnough() {
        let now = Date()
        let entry = TrashLedgerEntry(originalPath: "/a", trashPath: "/Users/x/.Trash/a",
                                     date: now.addingTimeInterval(-35 * day), fileID: 1, bytes: 10)
        let item = AutoSweepPreview.Item(kind: .trash, path: entry.trashPath, name: "a", bytes: 10, ledgerEntry: entry)
        XCTAssertTrue(AutoSweepApproval.stillAllowed(item, rules: rules(trashDays: 30), now: now) { _ in .distantPast })
        XCTAssertFalse(AutoSweepApproval.stillAllowed(item, rules: rules(trashDays: 60), now: now) { _ in .distantPast },
                       "Days raised after the ask: removing it now would be early, and it's permanent")
        XCTAssertFalse(AutoSweepApproval.stillAllowed(item, rules: rules(trash: false), now: now) { _ in .distantPast })
    }

    func testFilterDropsWhatNoLongerPassesAndChecksEachProjectOnce() {
        let now = Date()
        let preview = AutoSweepPreview(date: now, scheduled: true, daily: true, items: [
            nodeModules(modifiedDaysAgo: 50, now: now),
            .init(kind: .cache, path: "/web/.next", name: ".next", bytes: 5, project: "/code/web",
                  modified: now.addingTimeInterval(-50 * day)),
            .init(kind: .process, path: "12@34", name: "vite", bytes: 1),
            .init(kind: .download, path: "/d/x.dmg", name: "x.dmg", bytes: 3)
        ])
        var lookups = 0
        let result = AutoSweepApproval.filter(preview, rules: rules(processes: false), now: now) { _ in
            lookups += 1
            return now.addingTimeInterval(-2 * self.day)
        }
        XCTAssertEqual(result.preview.items.map(\.path), ["/d/x.dmg"])
        XCTAssertEqual(result.dropped, 3)
        XCTAssertEqual(lookups, 1)
    }

    func testAskExpiresAfterADayOrAtTheNextSlot() {
        let asked = Date()
        let ask = AutoSweepPreview(date: asked, scheduled: true, daily: false, items: [])
        XCTAssertFalse(AutoSweepApproval.isExpired(ask, now: asked.addingTimeInterval(3600), nextSlot: nil))
        XCTAssertTrue(AutoSweepApproval.isExpired(ask, now: asked.addingTimeInterval(25 * 3600), nextSlot: nil))
        let slot = asked.addingTimeInterval(6 * 3600)
        XCTAssertFalse(AutoSweepApproval.isExpired(ask, now: asked.addingTimeInterval(5 * 3600), nextSlot: slot))
        XCTAssertTrue(AutoSweepApproval.isExpired(ask, now: asked.addingTimeInterval(7 * 3600), nextSlot: slot))
    }

    func testChangedApprovalResetsTheCount() {
        var ladder = AutoSweepTrustLadder()
        XCTAssertFalse(ladder.recordApproval(changed: false))
        XCTAssertFalse(ladder.recordApproval(changed: false))
        XCTAssertFalse(ladder.recordApproval(changed: true), "Unticking something in Review isn't a clean approval")
        XCTAssertEqual(ladder.approvedInARow, 0)
        XCTAssertFalse(ladder.recordApproval(changed: false))
        XCTAssertFalse(ladder.recordApproval(changed: false))
        XCTAssertTrue(ladder.recordApproval(changed: false))
    }

    // MARK: Preview copy

    func testPreviewSentenceAndSafety() {
        let gb: Int64 = 1_000_000_000
        let preview = AutoSweepPreview(date: Date(), scheduled: true, daily: false, items: [
            .init(kind: .cache, path: "/a", name: "a", bytes: 3 * gb),
            .init(kind: .dependency, path: "/p/node_modules", name: "node_modules", bytes: 2 * gb)
        ])
        XCTAssertEqual(preview.totalBytes, 5 * gb)
        XCTAssertEqual(preview.sentence,
                       "Caches \(FileSizeHelper.formatBytes(3 * gb)) and 1 stale node_modules \(FileSizeHelper.formatBytes(2 * gb))")
        XCTAssertEqual(preview.safetySentence, "All safe, all to the Trash.")
        XCTAssertEqual(preview.keeping(["/a"]).items.map(\.path), ["/a"])

        let withTrash = AutoSweepPreview(date: Date(), scheduled: false, daily: true, items: [
            .init(kind: .trash, path: "/t", name: "t", bytes: gb)
        ])
        XCTAssertTrue(withTrash.hasPermanent)
        XCTAssertEqual(withTrash.safetySentence, "Furl’s old Trash items are removed for good.")
    }

    func testWhyNamesTheRuleAndTheApproval() {
        let caches = [AutoSweepRunPart(rule: .caches, itemCount: 3, bytes: 10)]
        XCTAssertEqual(AutoSweepWhy.text(parts: caches, frequency: .weekly, approved: true, processHours: 1),
                       "Why: weekly rule “Clean caches and stale node_modules”. You approved it.")
        let processes = [AutoSweepRunPart(rule: .processes, itemCount: 2, bytes: 10)]
        XCTAssertEqual(AutoSweepWhy.text(parts: processes, frequency: .weekly, approved: false, processHours: 1),
                       "Why: their agent session closed over an hour ago.")
        XCTAssertNil(AutoSweepWhy.text(parts: [AutoSweepRunPart(rule: .caches, itemCount: 0, bytes: 0)],
                                       frequency: .weekly, approved: false, processHours: 1))
    }

    // MARK: Suggestion

    private func junkClean(daysAgo: Double, bytes: Int64 = 3_000_000_000, automatic: Bool = false,
                           now: Date) -> ActivityEntry {
        ActivityEntry(date: now.addingTimeInterval(-daysAgo * 86_400), kind: .cleanup,
                      title: SidebarSection.junk.rawValue, detail: "", itemCount: 1,
                      diskBytes: bytes, automatic: automatic)
    }

    func testSuggestionAfterTwoManualCleansWhileOff() {
        let now = Date()
        let one = [junkClean(daysAgo: 3, now: now)]
        XCTAssertNil(AutoSweepSuggestion.offer(entries: one, mode: .off, dismissedAt: nil, now: now))
        let two = one + [junkClean(daysAgo: 10, bytes: 1_000_000_000, now: now)]
        let offer = AutoSweepSuggestion.offer(entries: two, mode: .off, dismissedAt: nil, now: now)
        XCTAssertEqual(offer?.cleanCount, 2)
        XCTAssertEqual(offer?.typicalBytes, 2_000_000_000)
        XCTAssertNil(AutoSweepSuggestion.offer(entries: two, mode: .askFirst, dismissedAt: nil, now: now),
                     "Only offered while Auto-Sweep is off")
    }

    func testSuggestionIgnoresOldAutomaticAndDismissedCleans() {
        let now = Date()
        let entries = [junkClean(daysAgo: 40, now: now), junkClean(daysAgo: 2, automatic: true, now: now),
                       junkClean(daysAgo: 5, now: now), junkClean(daysAgo: 4, now: now)]
        XCTAssertNotNil(AutoSweepSuggestion.offer(entries: entries, mode: .off, dismissedAt: nil, now: now))
        // "Not now" three days ago: the two cleans before it no longer count.
        XCTAssertNil(AutoSweepSuggestion.offer(entries: entries, mode: .off,
                                               dismissedAt: now.addingTimeInterval(-3 * 86_400), now: now))
    }
}
