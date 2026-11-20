import Foundation

/// Connects Processes & Sessions to the menu bar popover and the Auto-Sweep rule.
@MainActor
enum ProcessesIntegration {
    private static let provider = ProcessesMenuBarProvider(store: .shared)

    static func connect(to autoSweep: AutoSweepStore) {
        autoSweep.menuBarProviders = [provider]
        autoSweep.previewLeftoverProcesses = { idleHours in
            await ProcessesStore.shared.leftoversDue(orphanedForAtLeast: idleHours).map {
                AutoSweepPreview.Item(kind: .process, path: $0.id, name: $0.displayName,
                                      bytes: Int64(clamping: $0.memoryBytes),
                                      detail: $0.cwd.map(AppState.shortPath) ?? $0.agentName)
            }
        }
        autoSweep.stopLeftoverProcesses = { idleHours, onlyIDs in
            // The Auto-Sweep run records these in its History; don't log them twice in Activity.
            ActivityLog.shared.suppressProcessStops = true
            let outcome = await ProcessesStore.shared.stopLeftovers(orphanedForAtLeast: idleHours, onlyIDs: onlyIDs)
            ActivityLog.shared.suppressProcessStops = false
            guard outcome.count > 0 else { return nil }
            return AutoSweepRunPart(
                rule: .processes,
                itemCount: outcome.count,
                bytes: Int64(clamping: outcome.bytes),
                detail: "Leftover dev servers and watchers whose agent session ended over \(idleHours) h ago (memory freed)"
            )
        }
    }
}

/// "3 leftover dev servers · 1.2 GB RAM · Stop" in the menu bar popover.
@MainActor
final class ProcessesMenuBarProvider: MenuBarExtraProvider {
    private let store: ProcessesStore

    init(store: ProcessesStore) {
        self.store = store
    }

    var menuBarRows: [MenuBarExtraRow] {
        var rows: [MenuBarExtraRow] = []
        let count = store.leftoverCount
        if count > 0 {
            let memory = FileSizeHelper.formatBytes(Int64(clamping: store.leftoverMemoryBytes))
            let noun = count == 1 ? "leftover process" : "leftover processes"
            rows.append(MenuBarExtraRow(
                id: "processes.leftovers",
                // Menu bar board: the activity trace in memory blue.
                systemImage: "waveform.path.ecg",
                tint: .blue,
                title: "\(count) \(noun)",
                detail: "\(memory) RAM",
                actionTitle: "Stop",
                confirmation: "Stop \(count) \(noun) left behind by ended agent sessions? They're asked to quit cleanly first.",
                action: { [store] in
                    await store.stopAllLeftovers()
                }
            ))
        }
        let idle = store.idleSessionCount
        if idle > 0 {
            rows.append(MenuBarExtraRow(
                id: "processes.idle",
                // Menu bar board: clock in Theme.warning (Idle uses warning).
                systemImage: "clock",
                tint: .orange,
                title: idle == 1 ? "1 idle agent session" : "\(idle) idle agent sessions",
                detail: nil,
                actionTitle: "Review",
                action: {
                    AppWindows.showMain(section: .processes, state: AppServices.state)
                }
            ))
        }
        return rows
    }

    func menuBarWillAppear() {
        Task { await store.refresh() }
    }
}
