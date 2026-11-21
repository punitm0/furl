import XCTest
@testable import Furl

/// FirstScan board: the safe number only counts finished parts and never goes down while a scan
/// streams in. FirstClean board: which three items are offered, and when the guide isn't offered.
@MainActor
final class FirstScanTests: XCTestCase {
    private func junk(_ path: String, bytes: Int64, risk: RiskLevel = .safe,
                      category: JunkCategory = .packageCaches) -> JunkItem {
        JunkItem(id: path, name: URL(fileURLWithPath: path).lastPathComponent, path: path, category: category,
                 risk: risk, sizeBytes: bytes, modifiedDate: nil, reason: "")
    }

    private func plan(_ items: [JunkItem], ticked: Set<String>? = nil) -> AppState.SafeCleanupPlan {
        AppState.safeCleanupPlan(junk: items, ticked: ticked ?? Set(items.map(\.id)), isProtected: { _ in false })
    }

    // MARK: - Safe number never goes down

    /// Each finished check adds its items (as `scanJunk` merges them); the number after each must be ≥ before.
    private func assertNeverDecreases(_ batches: [[JunkItem]], file: StaticString = #filePath, line: UInt = #line) {
        var seen: [JunkItem] = []
        var last: Int64 = 0
        for batch in batches {
            seen += batch.filter { item in !seen.contains { $0.id == item.id } }
            let bytes = plan(seen).bytes
            XCTAssertGreaterThanOrEqual(bytes, last, "safe number went down after \(batch.map(\.path))", file: file, line: line)
            last = bytes
        }
    }

    func testSafeNumberGrowsAsPartsFinish() {
        assertNeverDecreases([
            [junk("/h/Library/Caches/Homebrew", bytes: 1_900), junk("/h/.npm", bytes: 2_800)],
            [junk("/h/Library/Developer/Xcode/DerivedData", bytes: 3_200, category: .devArtifacts)],
            [junk("/h/Library/Caches/com.example.App", bytes: 600, category: .systemCaches),
             junk("/h/Library/Logs/Thing", bytes: 50, category: .logsAndCrash)],
            // A part that finds only non-Safe items leaves the number where it was.
            [junk("/h/Downloads/big.dmg", bytes: 9_000, risk: .review, category: .installers)],
            []
        ])
    }

    func testNestedItemsNeverMakeTheNumberGoDown() {
        // A child first, then its parent (which holds it); then another child of an already counted parent.
        assertNeverDecreases([
            [junk("/p/app/node_modules/.cache", bytes: 400, category: .devArtifacts)],
            [junk("/p/app/node_modules", bytes: 1_000, category: .devArtifacts)],
            [junk("/p/app/node_modules/sub", bytes: 300, category: .devArtifacts)]
        ])
    }

    func testRandomArrivalOrderNeverDecreases() {
        // A small tree where each folder's size includes its children, as on disk.
        let leaves: [(String, Int64)] = [("/r/a/x", 10), ("/r/a/y", 20), ("/r/b/z", 30), ("/r/c", 5)]
        let a = junk("/r/a", bytes: 10 + 20 + 7)
        let b = junk("/r/b", bytes: 30 + 1)
        let all = leaves.map { junk($0.0, bytes: $0.1) } + [a, b]
        var generator = SeededGenerator(seed: 42)
        for _ in 0..<200 {
            let order = all.shuffled(using: &generator)
            // Random batch sizes, like checks finishing with different numbers of items.
            var batches: [[JunkItem]] = []
            var index = 0
            while index < order.count {
                let size = Int.random(in: 1...3, using: &generator)
                batches.append(Array(order[index..<min(order.count, index + size)]))
                index += size
            }
            assertNeverDecreases(batches)
        }
    }

    // MARK: - Which three

    func testPicksTheThreeBiggestFromThreeFolders() {
        let items = [
            junk("/h/Library/Caches/A", bytes: 5_000_000_000, category: .systemCaches),
            junk("/h/Library/Caches/B", bytes: 4_000_000_000, category: .systemCaches),  // same folder as A
            junk("/h/.npm", bytes: 2_800_000_000),
            junk("/h/Library/Developer/Xcode/DerivedData", bytes: 3_200_000_000, category: .devArtifacts),
            junk("/h/Library/Logs/Big", bytes: 1_000_000_000, category: .logsAndCrash)
        ]
        let picks = FirstCleanOffer.picks(plan: plan(items), junk: items)
        XCTAssertEqual(picks.map(\.path), ["/h/Library/Caches/A", "/h/Library/Developer/Xcode/DerivedData", "/h/.npm"])
    }

    func testPicksOnlyItemsTheSafeNumberCounts() {
        let items = [
            junk("/h/a/unticked", bytes: 9_000_000_000),
            junk("/h/b/review", bytes: 8_000_000_000, risk: .review),
            junk("/h/c/safe", bytes: 1_000_000_000)
        ]
        let p = plan(items, ticked: ["/h/b/review", "/h/c/safe"])
        XCTAssertEqual(FirstCleanOffer.picks(plan: p, junk: items).map(\.path), ["/h/c/safe"])
    }

    func testSkipsPicksTooSmallToShow() {
        let items = [
            junk("/h/Library/Caches/A", bytes: 1_800_000_000, category: .systemCaches),
            junk("/h/.npm", bytes: 170_000_000),
            junk("/h/projects/raw/.DS_Store", bytes: 12_000)
        ]
        XCTAssertEqual(FirstCleanOffer.picks(plan: plan(items), junk: items).map(\.path),
                       ["/h/Library/Caches/A", "/h/.npm"])
    }

    // MARK: - When it is offered

    private func picks(_ sizes: [Int64]) -> [FirstCleanOffer.Pick] {
        sizes.enumerated().map { FirstCleanOffer.Pick(item: junk("/f\($0.offset)/item", bytes: $0.element), bytes: $0.element) }
    }

    func testOfferedWhenThreeAddUpToHalfAGigabyte() {
        XCTAssertTrue(FirstCleanOffer.shouldOffer(picks([300_000_000, 150_000_000, 50_000_000]), hasCleanedBefore: false))
    }

    func testNotOfferedUnder500MB() {
        XCTAssertFalse(FirstCleanOffer.shouldOffer(picks([300_000_000, 150_000_000, 49_999_999]), hasCleanedBefore: false))
    }

    func testNotOfferedWhenNothingIsSafe() {
        XCTAssertFalse(FirstCleanOffer.shouldOffer([], hasCleanedBefore: false))
    }

    func testNotOfferedAfterAnyCleanup() {
        XCTAssertFalse(FirstCleanOffer.shouldOffer(picks([3_000_000_000]), hasCleanedBefore: true))
    }

    func testWhyLineIsThePopoversFirstLine() {
        let item = JunkItem(id: "d", name: "Xcode build files · DerivedData", path: "/h/Library/Developer/Xcode/DerivedData",
                            category: .devArtifacts, risk: .safe, sizeBytes: 1, modifiedDate: nil, reason: "")
        let first = WhySafe.junk(item, deletionMode: .moveToTrash).lines[0].text
        XCTAssertEqual(FirstCleanOffer.whyLine(item).lowercased(), first.lowercased())
        XCTAssertTrue(FirstCleanOffer.whyLine(item).first?.isUppercase == true)
    }

    // MARK: - Offered once, after the first scan that runs to the end

    private func record() -> FirstScanRecord {
        let name = "FirstScanTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return FirstScanRecord(defaults: defaults)
    }

    func testFirstFinishedScanMakesTheOfferDueOnce() {
        let r = record()
        XCTAssertTrue(r.isFirstScan)
        r.scanStarted(at: Date(timeIntervalSince1970: 0))
        r.scanFinished(at: Date(timeIntervalSince1970: 190))
        XCTAssertTrue(r.firstCleanDue)
        XCTAssertEqual(r.lastDuration, 190)
        XCTAssertFalse(r.isFirstScan)
        r.markFirstCleanOffered()
        XCTAssertFalse(r.firstCleanDue)

        r.scanStarted()
        r.scanFinished()
        XCTAssertFalse(r.firstCleanDue, "only the first scan offers it")
    }

    func testStoppedScanIsNotTheFirstScan() {
        let r = record()
        r.scanStarted()
        r.scanStopped()
        r.scanFinished()
        XCTAssertFalse(r.firstCleanDue)
        XCTAssertTrue(r.isFirstScan)
        XCTAssertNil(r.lastDuration)
    }

    func testOfferedFlagAndDurationAreRemembered() {
        let name = "FirstScanTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = FirstScanRecord(defaults: defaults)
        first.scanStarted(at: Date(timeIntervalSince1970: 0))
        first.scanFinished(at: Date(timeIntervalSince1970: 150))
        first.markFirstCleanOffered()

        let relaunched = FirstScanRecord(defaults: defaults)
        XCTAssertTrue(relaunched.firstCleanOffered)
        XCTAssertFalse(relaunched.firstCleanDue)
        XCTAssertEqual(relaunched.promise, "Your last scan took about 3 minutes and only read. You can use results as they arrive.")
    }

    func testPromiseBeforeTheFirstScanIsTheBriefsLine() {
        XCTAssertEqual(record().promise,
                       "A full scan takes about 2–5 minutes and only reads. You can use results as they arrive.")
        XCTAssertEqual(FirstScanRecord.durationText(40), "less than a minute")
        XCTAssertEqual(FirstScanRecord.durationText(70), "about a minute")
    }

    // MARK: - Undo re-checks the Trash

    func testUndoOnlyPutsBackItemsUnchangedInTheTrash() {
        let entry = TrashLedgerEntry(originalPath: "/h/.npm", trashPath: "/h/.Trash/.npm", date: Date(), fileID: 7, bytes: 10)
        let stamp = CleanupStamp(kind: .directory, modified: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(FirstCleanOffer.isUnchangedInTrash(entry, stamp: stamp, isStillOurs: { _ in true }, matches: { _, _ in true }))
        // Emptied from the Trash, or another item now has that name.
        XCTAssertFalse(FirstCleanOffer.isUnchangedInTrash(entry, stamp: stamp, isStillOurs: { _ in false }, matches: { _, _ in true }))
        // Still ours but changed (date or size).
        XCTAssertFalse(FirstCleanOffer.isUnchangedInTrash(entry, stamp: stamp, isStillOurs: { _ in true }, matches: { _, _ in false }))
        // No record of how it looked: don't guess.
        XCTAssertFalse(FirstCleanOffer.isUnchangedInTrash(entry, stamp: nil, isStillOurs: { _ in true }, matches: { _, _ in true }))
    }

    func testUndoRecheckWithRealFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FirstScanTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("item.bin")
        try Data(count: 64).write(to: file)
        let entry = TrashLedgerEntry(originalPath: "/elsewhere/item.bin", trashPath: file.path, date: Date(), bytes: 64)
        let stamp = CleanupStamp.read(file.path, includeSize: true)
        XCTAssertTrue(FirstCleanOffer.isUnchangedInTrash(entry, stamp: stamp))

        try Data(count: 128).write(to: file)  // changed while in the Trash
        XCTAssertFalse(FirstCleanOffer.isUnchangedInTrash(entry, stamp: stamp))
    }
}

/// Deterministic shuffles for the arrival-order test.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
