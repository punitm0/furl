import Darwin
import Foundation

/// Sends signals with strict safety checks. Never signals PID 0/1, Furl itself, its
/// ancestors, processes of other users, or a PID that has been reused since it was scanned.
enum ProcessTerminator {
    struct Outcome: Sendable {
        var exited: [ProcessRef] = []
        var stillRunning: [ProcessRef] = []
        var refused: [ProcessRef] = []
        var reclaimedBytes: UInt64 = 0
    }

    /// True while the exact process (PID + start time) still exists and is not a zombie.
    static func isAlive(_ ref: ProcessRef) -> Bool {
        guard let identity = ProcessTable.identity(of: ref.pid) else { return false }
        return identity.startMicros == ref.startMicros && !identity.isZombie
    }

    static func isSafeTarget(_ ref: ProcessRef) -> Bool {
        let me = getpid()
        guard ref.pid > 1, ref.pid != me else { return false }
        guard let identity = ProcessTable.identity(of: ref.pid) else { return false }
        guard identity.uid == getuid(), identity.startMicros == ref.startMicros else { return false }
        return !ancestorsOfSelf().contains(ref.pid)
    }

    private static func ancestorsOfSelf() -> Set<Int32> {
        var result: Set<Int32> = []
        var current = getppid()
        var steps = 0
        while current > 1, steps < 64, let identity = ProcessTable.identity(of: current) {
            result.insert(current)
            current = identity.ppid
            steps += 1
        }
        return result
    }

    /// Sends `signal` to every safe target, then waits up to `timeout` for them to exit.
    /// `memory` maps a ref to the bytes it held, so reclaimed memory can be reported.
    static func terminate(
        _ refs: [ProcessRef],
        signal: Int32,
        timeout: TimeInterval,
        memory: [ProcessRef: UInt64] = [:]
    ) async -> Outcome {
        var outcome = Outcome()
        var pending: [ProcessRef] = []
        // Signal children before parents (refs are root-first) so wrappers don't respawn them.
        for ref in refs.reversed() {
            guard isSafeTarget(ref) else {
                if isAlive(ref) { outcome.refused.append(ref) } else { outcome.exited.append(ref) }
                continue
            }
            if kill(ref.pid, signal) == 0 || errno == ESRCH {
                pending.append(ref)
            } else {
                outcome.refused.append(ref)
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while !pending.isEmpty {
            pending.removeAll { ref in
                if isAlive(ref) { return false }
                outcome.exited.append(ref)
                return true
            }
            if pending.isEmpty || Date() >= deadline { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        outcome.stillRunning = pending
        outcome.reclaimedBytes = outcome.exited.reduce(0) { $0 + (memory[$1] ?? 0) }
        return outcome
    }
}
