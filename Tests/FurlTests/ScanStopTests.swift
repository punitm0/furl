import XCTest
@testable import Furl

/// A stopped scan must never be shown as a finished "nothing found".
final class ScanStopTests: XCTestCase {
    func testStoppedEmptyScanStaysUnscanned() {
        XCTAssertTrue(AppState.countsAsScanned(stopped: false, foundAny: false), "a finished empty scan is a real result")
        XCTAssertTrue(AppState.countsAsScanned(stopped: false, foundAny: true))
        XCTAssertTrue(AppState.countsAsScanned(stopped: true, foundAny: true), "partial results stay on screen")
        XCTAssertFalse(AppState.countsAsScanned(stopped: true, foundAny: false), "stopped with nothing found is not 'none found'")
    }

    /// Stop during "Looking through your home folder" used to wait for the whole shared walk.
    func testWaitReturnsSoonAfterStop() async {
        let slowWalk = Task<FileIndex?, Never>.detached {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return nil
        }
        defer { slowWalk.cancel() }
        let progress = ScanProgress()
        Task.detached {
            try? await Task.sleep(nanoseconds: 50_000_000)
            progress.cancel()
        }
        let started = Date()
        let outcome = await ScanIndexCache.wait(for: slowWalk, unlessStopped: progress, pollInterval: 10_000_000)
        guard case .stopped = outcome else { return XCTFail("expected .stopped, got \(outcome)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testWaitPassesThroughFinishedWalk() async {
        let walk = Task<FileIndex?, Never>.detached { nil }
        let outcome = await ScanIndexCache.wait(for: walk, unlessStopped: ScanProgress(), pollInterval: 10_000_000)
        guard case .finished(let index) = outcome else { return XCTFail("expected .finished, got \(outcome)") }
        XCTAssertNil(index)
    }

    func testWaitWithAlreadyStoppedProgress() async {
        let walk = Task<FileIndex?, Never>.detached {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return nil
        }
        defer { walk.cancel() }
        let progress = ScanProgress()
        progress.cancel()
        guard case .stopped = await ScanIndexCache.wait(for: walk, unlessStopped: progress) else {
            return XCTFail("expected .stopped")
        }
    }
}
