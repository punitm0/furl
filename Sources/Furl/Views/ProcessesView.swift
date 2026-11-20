import AppKit
import SwiftUI

/// "Processes & Sessions": finds what AI coding agents left running and the sessions still open.
/// Construct with `ProcessesView(store: ProcessesStore.shared)`.
struct ProcessesView: View {
    @ObservedObject var store: ProcessesStore

    @State private var confirmStopIDs: Set<String>?
    @State private var confirmEndSession: AgentSession?
    @State private var evidenceFor: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            // The tables have fixed columns that need 760 pt. When the screen is narrower (a small
            // window with the tray or Inspector open) they scroll sideways instead of the whole
            // screen being clipped on its left edge.
            GeometryReader { proxy in
                let narrow = proxy.size.width < Self.minContentWidth
                ScrollView(narrow ? [.vertical, .horizontal] : .vertical) {
                    VStack(alignment: .leading, spacing: 16) {
                        if let banner = store.banner {
                            BannerView(banner: banner) { store.banner = nil }
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        leftoversSection
                        sessionsSection
                        privacyFootnote
                    }
                    .padding(.horizontal, Theme.Space.page)
                    .padding(.vertical, 20)
                    .frame(width: max(proxy.size.width, Self.minContentWidth))
                    .animation(.easeInOut(duration: 0.2), value: store.banner)
                }
            }
        }
        .cleanSlateScreen()
        .onAppear { store.beginLiveUpdates() }
        .onDisappear { store.endLiveUpdates() }
        .confirmationDialog(
            confirmStopTitle,
            isPresented: Binding(get: { confirmStopIDs != nil }, set: { if !$0 { confirmStopIDs = nil } }),
            titleVisibility: .visible
        ) {
            Button("Stop", role: .destructive) {
                if let ids = confirmStopIDs { Task { await store.stopLeftovers(ids: ids) } }
                confirmStopIDs = nil
            }
            Button("Cancel", role: .cancel) { confirmStopIDs = nil }
        } message: {
            Text("Furl asks each one to quit. Anything that ignores it can be force quit afterwards. Unsaved state in those processes is lost.")
        }
        .confirmationDialog(
            confirmEndSession.map { "End \($0.agentName) in \($0.projectName)?" } ?? "",
            isPresented: Binding(get: { confirmEndSession != nil }, set: { if !$0 { confirmEndSession = nil } }),
            titleVisibility: .visible
        ) {
            Button("End Session", role: .destructive) {
                if let session = confirmEndSession { Task { await store.endSession(id: session.id) } }
                confirmEndSession = nil
            }
            Button("Cancel", role: .cancel) { confirmEndSession = nil }
        } message: {
            if let hint = confirmEndSession?.resumeHint {
                Text("The agent is asked to exit gracefully and keeps its history. Pick it up again later: \(hint)")
            } else {
                Text("The agent is asked to exit gracefully.")
            }
        }
    }

    private var confirmStopTitle: String {
        let count = confirmStopIDs?.count ?? 0
        return count == 1 ? "Stop 1 leftover process?" : "Stop \(count) leftover processes?"
    }

    // MARK: Header

    private var header: some View {
        ScreenHeader(title: "Processes & Sessions", subtitle: "AI coding agents end. The servers they started often don't.") {
            agentChips
            Button {
                Task { await store.refresh() }
            } label: {
                if store.isRefreshing && !store.hasLoaded {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            .buttonStyle(.borderless)
            .help("Refresh now (updates automatically every few seconds)")
        }
    }

    private var agentChips: some View {
        ViewThatFits(in: .horizontal) {
            chipRow
            ScrollView(.horizontal, showsIndicators: false) { chipRow }
        }
        .frame(maxWidth: 640)
    }

    private var chipRow: some View {
            HStack(spacing: 6) {
                AgentChip(title: "All agents", agent: nil, count: nil, isOn: store.agentFilter == nil) {
                    store.agentFilter = nil
                }
                ForEach(store.chipAgents) { agent in
                    AgentChip(title: agent.displayName, agent: agent, count: store.count(for: agent), isOn: store.agentFilter == agent) {
                        store.agentFilter = store.agentFilter == agent ? nil : agent
                    }
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 1)
    }

    // MARK: Leftovers

    private var visibleLeftovers: [LeftoverProcess] { store.filteredLeftovers }

    private var selectedVisibleIDs: Set<String> {
        store.selectedLeftoverIDs.intersection(visibleLeftovers.map(\.id))
    }

    private var leftoversSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                sectionTitle("Left running by closed sessions",
                             subtitle: "The agent that started each one has exited. Nothing is attached to them.")
                if !visibleLeftovers.isEmpty {
                    let bytes = visibleLeftovers.reduce(UInt64(0)) { $0 + $1.memoryBytes }
                    Text(FileSizeHelper.formatBytes(Int64(clamping: bytes)))
                        .font(Theme.display(22))
                        .monospacedDigit()
                        .foregroundStyle(Theme.memory)
                        .help("Memory used by these processes")
                    stopButton
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }

            if !store.hasLoaded {
                // ProcessesStates board: spinner and 13 pt secondary text side by side, padding 28.
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for leftover processes…")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.inkSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(28)
            } else if visibleLeftovers.isEmpty {
                emptyLeftovers
            } else {
                leftoverHeaderRow
                ForEach(visibleLeftovers) { item in
                    leftoverRow(item)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                }
            }

            // ProcessesStates "Loading": the card shows only the spinner line, no auto-stop footer.
            if store.hasLoaded {
                autoStopFooter
                    .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            }
        }
        .sectionCard()
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stopButton: some View {
        let selected = selectedVisibleIDs
        let allSelected = selected.count == visibleLeftovers.count
        let title = allSelected ? "Stop all \(selected.count)" : "Stop \(selected.count) selected"
        return Button {
            if selected.count == 1 {
                Task { await store.stopLeftovers(ids: selected) }
            } else {
                confirmStopIDs = selected
            }
        } label: {
            Text(title).monospacedDigit()
        }
        .buttonStyle(MemoryButtonStyle())
        .fixedSize()
        .disabled(selected.isEmpty || !store.stoppingIDs.isEmpty)
    }

    /// ProcessesStates board: centred seal, 14 pt title, 13 pt body, 12 pt "freed so far", padding 24, gap 6.
    private var emptyLeftovers: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 26))
                .foregroundStyle(Theme.sweep)
            Text("Nothing left running")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(store.agentFilter == nil
                 ? "No dev servers, watchers or emulators from closed agent sessions are using memory."
                 : "Nothing from closed \(store.agentFilter!.displayName) sessions is running.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSecondary)
            if store.reclaimedBytesThisSession > 0 {
                Text("\(FileSizeHelper.formatBytes(Int64(clamping: store.reclaimedBytesThisSession))) of memory freed so far.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private var leftoverHeaderRow: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { !visibleLeftovers.isEmpty && selectedVisibleIDs.count == visibleLeftovers.count },
                set: { on in
                    let ids = Set(visibleLeftovers.map(\.id))
                    if on { store.selectedLeftoverIDs.formUnion(ids) } else { store.selectedLeftoverIDs.subtract(ids) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.furlCheckbox)
            .help("Select all")
            .frame(width: Col.check, alignment: .leading)
            Text("PROCESS").frame(maxWidth: .infinity, alignment: .leading)
            Text("STARTED BY").frame(width: Col.agent, alignment: .leading)
            Text("PORT").frame(width: Col.port, alignment: .leading)
            Text("MEMORY").frame(width: Col.memory, alignment: .leading)
            Text("AGE").frame(width: Col.age, alignment: .leading)
            Color.clear.frame(width: Col.action, height: 1)
        }
        .font(.system(size: 11, weight: .semibold))
        .tracking(0.3)
        .foregroundStyle(Theme.inkSecondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Theme.surfaceSubtle)
    }

    private func leftoverRow(_ item: LeftoverProcess) -> some View {
        let isStopping = store.stoppingIDs.contains(item.id)
        let isStubborn = store.stubbornLeftoverIDs.contains(item.id)
        return HStack(spacing: 12) {
            SelectionCheckbox(id: item.id, selection: $store.selectedLeftoverIDs, disabled: isStopping)
                .frame(width: Col.check, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(item.displayName)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if store.autoStopLeftovers && item.autoStopExemption != nil {
                        NeverAutoStoppedBadge()
                    }
                    Button {
                        evidenceFor = evidenceFor == item.id ? nil : item.id
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Why Furl thinks this was left behind")
                    .popover(isPresented: Binding(
                        get: { evidenceFor == item.id },
                        set: { if !$0 { evidenceFor = nil } }
                    ), arrowEdge: .trailing) {
                        EvidencePopover(item: item)
                    }
                }
                Text(subtitle(for: item))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(item.summary)

            AgentLabel(agent: item.agent, name: item.agentName)
                .frame(width: Col.agent, alignment: .leading)

            Text(item.ports.isEmpty ? "none" : ":\(item.ports[0])" + (item.ports.count > 1 ? " +\(item.ports.count - 1)" : ""))
                .font(item.ports.isEmpty ? .system(size: 13) : .system(size: 12, design: .monospaced))
                .foregroundStyle(item.ports.isEmpty ? Theme.inkSecondary : Theme.ink)
                .lineLimit(1)
                .frame(width: Col.port, alignment: .leading)
                .help(item.ports.isEmpty ? "Not listening on any TCP port" : item.ports.map { "localhost:\($0)" }.joined(separator: ", "))

            Text(FileSizeHelper.formatBytes(Int64(clamping: item.memoryBytes)))
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .frame(width: Col.memory, alignment: .leading)

            Text(AgentProcessScanner.formatDuration(Date().timeIntervalSince(item.startedAt)))
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
                .frame(width: Col.age, alignment: .leading)
                .help("Started \(item.startedAt.formatted(date: .abbreviated, time: .shortened))")

            Group {
                if isStopping {
                    // ProcessesStates: the spinner sits centred in the 70 pt action column.
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else if isStubborn {
                    Button("Force Quit") {
                        Task { await store.forceQuitLeftovers(ids: [item.id]) }
                    }
                    .buttonStyle(RowButtonStyle(foreground: Theme.danger))
                    .help("It ignored the request to quit. Force quit sends SIGKILL.")
                } else {
                    Button("Stop") {
                        Task { await store.stopLeftovers(ids: [item.id]) }
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
            .controlSize(.small)
            .frame(width: Col.action, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            if let cwd = item.cwd {
                Button("Reveal Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)]) }
            }
            Button("Copy PID \(item.ref.pid)") { copy(String(item.ref.pid)) }
            Button("Copy Explanation") { copy(([item.summary] + item.evidence).joined(separator: "\n")) }
        }
    }

    private func subtitle(for item: LeftoverProcess) -> String {
        var parts: [String] = []
        if let cwd = item.cwd { parts.append(AgentProcessScanner.abbreviate(cwd)) }
        var kind = item.category == .process ? item.executableName : "\(item.executableName) \(item.category.rawValue)"
        if item.workerCount > 0 {
            kind += item.workerCount == 1 ? ", 1 worker" : ", \(item.workerCount) workers"
        }
        parts.append(kind)
        return parts.joined(separator: " · ")
    }

    private var autoStopFooter: some View {
        HStack(spacing: 8) {
            Toggle("Stop leftovers automatically after", isOn: $store.autoStopLeftovers)
                .toggleStyle(.furlCheckbox)
            FurlPopUp("Leftover limit", selection: $store.leftoverLimitMinutes, value: limitLabel(store.leftoverLimitMinutes)) {
                ForEach(ProcessesStore.leftoverLimitOptions, id: \.self) { minutes in
                    Text(limitLabel(minutes)).tag(minutes)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!store.autoStopLeftovers)
            Spacer()
            Text("Off by default. Only sends a polite quit request.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkTertiary)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Sessions

    private var sessionsSection: some View {
        let sessions = store.filteredSessions
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                sectionTitle("Open agent sessions",
                             subtitle: "Ended sessions can be picked up again, for example with claude --resume or codex resume.")
                HStack(spacing: 6) {
                    Toggle("End sessions idle for more than", isOn: $store.autoEndIdleSessions)
                        .toggleStyle(.furlCheckbox)
                    FurlPopUp("Idle limit", selection: $store.idleLimitMinutes, value: limitLabel(store.idleLimitMinutes)) {
                        ForEach(ProcessesStore.idleLimitOptions, id: \.self) { minutes in
                            Text(limitLabel(minutes)).tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!store.autoEndIdleSessions)
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
                .fixedSize()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }

            if !store.hasLoaded {
                EmptyView()
            } else if sessions.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "moon")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.inkSecondary)
                    Text(store.agentFilter == nil ? "No agent sessions are open." : "No open \(store.agentFilter!.displayName) sessions.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.inkSecondary)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            } else {
                ForEach(sessions) { session in
                    sessionRow(session)
                        .overlay(alignment: .top) {
                            if session.id != sessions.first?.id { Rectangle().fill(Theme.hairline).frame(height: 1) }
                        }
                }
            }
        }
        .sectionCard()
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        let state = store.activity[session.id]
        let isWorking = state?.status == .working
        let isEnding = store.endingSessionIDs.contains(session.id)
        let isStubborn = store.stubbornSessionIDs.contains(session.id)
        let now = Date()

        return HStack(spacing: 12) {
            AgentLabel(agent: session.agent, name: session.agentName)
                .frame(width: Col.sessionAgent, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.projectName)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(sessionSubtitle(session))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // ProcessesStates board: Working = sweep label on a freeableBar dot; Idle = Theme.warning; Checking = inkSecondary, dot at 50%.
            let statusColor: Color = state == nil ? Theme.inkSecondary : (isWorking ? Theme.sweep : Theme.warning)
            HStack(spacing: 6) {
                Circle()
                    .fill(state == nil ? Theme.inkSecondary.opacity(0.5) : (isWorking ? Theme.freeableBar : Theme.warning))
                    .frame(width: 7, height: 7)
                Text(state == nil ? "Checking" : (isWorking ? "Working" : "Idle"))
                    .font(.system(size: 13, weight: state == nil ? .regular : .medium))
                    .foregroundStyle(statusColor)
            }
            .frame(width: Col.status, alignment: .leading)

            Text(durationText(session, state: state, now: now))
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
                .frame(width: Col.duration, alignment: .leading)

            Group {
                if isEnding {
                    ProgressView().controlSize(.small)
                } else if isStubborn {
                    Button("Force Quit") {
                        Task { await store.forceQuitSession(id: session.id) }
                    }
                    .buttonStyle(RowButtonStyle(foreground: Theme.danger))
                    .frame(width: Col.sessionButton)
                } else if isWorking {
                    Text("Can't end while working")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.trailing)
                } else {
                    Button("End session") { confirmEndSession = session }
                        .buttonStyle(RowButtonStyle())
                        .frame(width: Col.sessionButton)
                        .disabled(state == nil)
                }
            }
            .controlSize(.small)
            .frame(width: Col.sessionAction, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .help(session.resumeHint.map { "Resume after ending: \($0)" } ?? "")
        .contextMenu {
            if let cwd = session.cwd {
                Button("Reveal Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)]) }
            }
            if let hint = session.resumeHint, hint.contains(" ") && !hint.hasPrefix("Reopen") {
                Button("Copy Resume Command") { copy(hint) }
            }
            Button("Copy PID \(session.ref.pid)") { copy(String(session.ref.pid)) }
        }
    }

    private func sessionSubtitle(_ session: AgentSession) -> String {
        var parts = [session.detail]
        if let cwd = session.cwd { parts.insert(AgentProcessScanner.abbreviate(cwd), at: 0) }
        parts.append(FileSizeHelper.formatBytes(Int64(clamping: session.memoryBytes)))
        if session.detachedCount > 0 {
            parts.append(session.detachedCount == 1 ? "1 background process" : "\(session.detachedCount) background processes")
        }
        return parts.joined(separator: " · ")
    }

    private func durationText(_ session: AgentSession, state: SessionActivity?, now: Date) -> String {
        guard let state else { return "running " + AgentProcessScanner.formatDuration(now.timeIntervalSince(session.startedAt)) }
        switch state.status {
        case .working:
            return "running " + AgentProcessScanner.formatDuration(now.timeIntervalSince(session.startedAt))
        case .idle:
            let idle = now.timeIntervalSince(state.since)
            return idle < 60 ? "idle" : "idle " + AgentProcessScanner.formatDuration(idle)
        }
    }

    private var privacyFootnote: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield")
                .font(.system(size: 12))
            Text("Works offline. Furl reads the local process list only; it never leaves your Mac.")
                .font(Theme.caption)
        }
        .foregroundStyle(Theme.inkTertiary)
        .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
    }

    // MARK: Helpers

    private func limitLabel(_ minutes: Int) -> String {
        if minutes % 60 == 0 { return minutes == 60 ? "1 hour" : "\(minutes / 60) hours" }
        return "\(minutes) minutes"
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Column widths from the Processes board grids.
    private static let minContentWidth: CGFloat = 760

    private enum Col {
        static let check: CGFloat = 28
        static let agent: CGFloat = 120
        static let port: CGFloat = 80
        static let memory: CGFloat = 90
        static let age: CGFloat = 80
        static let action: CGFloat = 70
        static let sessionAgent: CGFloat = 120
        static let status: CGFloat = 110
        static let duration: CGFloat = 110
        static let sessionAction: CGFloat = 110
        /// "End session" / "Force Quit" sit right-aligned at 100 inside the 110 column (ProcessesStates).
        static let sessionButton: CGFloat = 100
    }
}

// MARK: - Pieces

private struct AgentChip: View {
    let title: String
    let agent: AgentKind?
    let count: Int?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let agent { AgentLogo(agent: agent, size: 12) }
                Text(title)
                    .font(.system(size: 12, weight: isOn ? .medium : .regular))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isOn ? Theme.onToast : Theme.inkSecondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            // Processes board: the selected chip is ink-filled (toast colours), the rest outlined.
            .foregroundStyle(isOn ? Theme.onToast : Theme.ink)
            .background(isOn ? Theme.toastBackground : Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? Theme.toastBorder : Theme.controlBorder, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct AgentLabel: View {
    let agent: AgentKind
    let name: String

    var body: some View {
        HStack(spacing: 6) {
            AgentLogo(agent: agent, size: 13)
                .frame(width: 20, height: 20)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            Text(name)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
        }
    }
}

/// "Stop all" on the leftovers card: memory blue, like the total beside it.
private struct MemoryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(Theme.onSweep)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Theme.memory, in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
    }
}

/// Row action (Stop, End session): fills its column, 28pt, outlined.
private struct RowButtonStyle: ButtonStyle {
    var foreground: Color = Theme.ink
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.controlBorder, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private extension View {
    /// Section card from the Processes board: surface, hairline border, 14pt corners.
    func sectionCard() -> some View {
        self
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// ProcessesStates board: width 360, padding 14, gap 8; 13 pt semibold name, 12 pt body and evidence lines.
private struct EvidencePopover: View {
    let item: LeftoverProcess

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AgentLogo(agent: item.agent, size: 16)
                Text(item.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("PID \(item.ref.pid)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.inkSecondary)
            }
            Text(item.summary + ".")
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(item.evidence, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 11))
                    Text(line)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Theme.inkSecondary)
            }
            if item.workerCount > 0 {
                Text("Stopping it also stops its \(item.workerCount) child process\(item.workerCount == 1 ? "" : "es").")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
    }
}

/// ProcessesStates board: padding 12, radius 10, 10% tint (warning for errors, sweep otherwise), 16 pt icon, 13 pt message.
private struct BannerView: View {
    let banner: ProcessesBanner
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: banner.isError ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(banner.isError ? Theme.warning : Theme.sweep)
            VStack(alignment: .leading, spacing: 6) {
                Text(banner.message)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = banner.resumeHint {
                    HStack(spacing: 6) {
                        Text(hint.hasPrefix("Reopen") ? hint : "Resume with")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.inkSecondary)
                        if !hint.hasPrefix("Reopen") {
                            Text(hint)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.inkSecondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                                .textSelection(.enabled)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(hint, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.inkSecondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Copy")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(12)
        .background((banner.isError ? Theme.warning : Theme.sweep).opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Design decision v45: shown after the process name only while auto-stop is on.
private struct NeverAutoStoppedBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.fill")
            Text("Never auto-stopped")
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.accentGray.fg)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(Theme.accentGray.bg))
        .fixedSize()
        .help("Databases, tmux and screen sessions and tunnels are never stopped automatically. Stop still works.")
    }
}
