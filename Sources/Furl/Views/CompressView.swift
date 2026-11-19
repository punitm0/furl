import AppKit
import SwiftUI

/// Lossless compression: smaller files, identical content.
struct CompressView: View {
    @ObservedObject var store: CompressStore
    @State private var showConfirm = false
    @State private var showSkipped = false
    @State private var listedCategory: CompressCategory?
    @ObservedObject private var installer = ToolInstaller.shared
    /// Tools the user waved off with "Not now" (comma-separated raw values).
    @AppStorage("dismissedToolRecommendations") private var dismissedToolsRaw = ""
    /// Estimate when an install started, for the "went from … to …" line after the rescan.
    @State private var estimateBeforeInstall: [CompressCategory: Int64]?
    /// The rescan after an install finished and the card shows its before/after; the next scan closes it.
    @State private var toolResultShown = false
    /// An install finished mid-scan: that scan detected tools before the install, so scan again once it ends.
    @State private var rescanAfterScan = false

    private var dismissedTools: Set<OptionalTool> {
        Set(dismissedToolsRaw.split(separator: ",").compactMap { OptionalTool(rawValue: String($0)) })
    }

    private var recommendedTools: [OptionalTool] { store.recommendedTools(dismissed: dismissedTools) }

    /// Only after a scan, and only while it recommends something or an install from this page is in flight.
    private var showsToolsCard: Bool {
        guard store.hasScanned || store.isScanning else { return false }
        // While busy, keep an install in progress or its "Installed · Scanning…" result on screen, but don't
        // offer fresh installs: one started now would race the scan's tool detection.
        let losslessInFlight = OptionalTool.lossless.contains { installer.state($0) != nil }
        if store.isBusy { return losslessInFlight }
        return !recommendedTools.isEmpty || losslessInFlight
    }

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    /// Lossless and Shrink are two ways to the same goal, so the screen asks which one up front.
    enum Mode: String, CaseIterable { case lossless, shrink }
    @AppStorage("compressMode") private var modeRaw = Mode.lossless.rawValue
    private var mode: Mode { Mode(rawValue: modeRaw) ?? .lossless }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Compress", subtitle: "Make files smaller. Choose identical files, or far smaller files at a lower quality.") {
                EmptyView()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    modeChooser
                    if mode == .shrink {
                        VStack(alignment: .leading, spacing: 14) {
                            shrinkIntro
                            ShrinkSection(store: store.shrink, compressIsBusy: store.isBusy, showsToggle: false)
                        }
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                    } else {
                        losslessContent
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.vertical, 22)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: modeRaw)
            }
        }
        .background(Theme.ground)
        .onAppear { if mode == .shrink { store.shrink.options.enabled = true } }
        .onChange(of: installer.finishedRuns) { _, _ in
            store.shrink.refreshTools()
            // New lossless tools unlock formats the last scan skipped: scan again so they're counted.
            guard store.hasScanned || store.isBusy,
                  installer.lastRunInstalled.contains(where: { OptionalTool.lossless.contains($0) }) else { return }
            // A scan or compress in flight detected tools before the install: rescan once it's idle.
            if store.isBusy { rescanAfterScan = true } else { Task { await store.scan() } }
        }
        .onChange(of: installer.isRunning) { _, running in
            if running, estimateBeforeInstall == nil, store.hasScanned, !store.isScanning,
               store.live?.phase != .stopped {
                estimateBeforeInstall = categorySavings()
            }
        }
        .onChange(of: store.isScanning) { _, scanning in
            if scanning {
                // A later scan closes the before/after card.
                if toolResultShown { closeToolResult() }
            } else if rescanAfterScan {
                // The rescan runs when the store goes idle; this scan's numbers predate the install.
            } else if estimateBeforeInstall != nil, !installer.isRunning,
                      // A stopped scan's estimate is partial: wait for a full one before comparing.
                      store.live?.phase != .stopped,
                      OptionalTool.lossless.contains(where: { installer.state($0) == .installed }) {
                toolResultShown = true
            }
        }
        .onChange(of: store.isBusy) { _, busy in
            guard !busy, rescanAfterScan else { return }
            rescanAfterScan = false
            Task { await store.scan() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Tools installed in Terminal while Furl was in the background.
            store.shrink.refreshTools()
        }
        .navigationTitle("Compress")
        .confirmationDialog(confirmTitle, isPresented: $showConfirm, titleVisibility: .visible) {
            Button(store.options.keepOriginalsInTrash ? "Compress" : "Compress and Delete Originals",
                   role: store.options.keepOriginalsInTrash ? nil : .destructive) {
                Task { await store.run() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .sheet(item: $listedCategory) { category in
            CandidateListSheet(category: category, items: store.candidates(for: category))
        }
    }


    @ViewBuilder
    private var toolsCard: some View {
        if showsToolsCard {
            OptionalToolsCard(
                recommended: recommendedTools, finds: store.toolFinds, isRescanning: store.isScanning,
                installsBlocked: store.isBusy,
                estimateChange: toolResultShown ? estimateChange : nil,
                onNotNow: {
                    dismissedToolsRaw = (dismissedTools.union(recommendedTools)).map(\.rawValue).sorted().joined(separator: ",")
                    closeToolResult()
                },
                onClose: closeToolResult
            )
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var losslessContent: some View {
        if store.isScanning && !store.hasScanned {
            VStack(alignment: .leading, spacing: 16) {
                // Keeps "Installed … · Scanning…" up from the first moment of the post-install rescan.
                toolsCard
                scanningState.frame(minHeight: 320).card(padding: 0)
            }
        } else if !store.hasScanned {
            EmptyStatePlaceholder(
                systemImage: "rectangle.compress.vertical",
                title: "Compress Without Losing Anything",
                message: "Finds files and old folders that can be stored smaller with identical content. Works offline; your files never leave your Mac, and originals go to the Trash so you can undo.",
                buttonTitle: "Find Savings"
            ) {
                Task { await store.scan() }
            }
            .frame(minHeight: 320)
            .card(padding: 0)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                LiveScanStripSlot(status: store.live, onStop: { store.cancel() },
                                  onRescan: { Task { await store.scan() } })
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                if store.isRunning {
                    runningCard
                } else if let run = store.lastRun {
                    resultsCard(run)
                } else if let undo = store.lastUndoSummary {
                    undoBanner(undo)
                }
                heroCard
                toolsCard
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(CompressCategory.allCases) { category in
                        categoryCard(category)
                    }
                }
                skippedNote
            }
        }
    }

    private var modeChooser: some View {
        HStack(spacing: 12) {
            modeCard(.lossless, icon: "checkmark.seal", title: "Lossless",
                     badge: "Identical", badgeColor: Theme.sweep,
                     detail: "Same files, stored smaller. Every result is checked byte for byte or pixel for pixel.")
            modeCard(.shrink, icon: "arrow.down.right.and.arrow.up.left", title: "Shrink",
                     badge: "Lowers quality", badgeColor: Theme.warning,
                     detail: "Photos, videos and PDFs re-encoded smaller. Saves far more, and you preview before anything changes.")
        }
        .disabled(store.isBusy || store.shrink.isBusy)
    }

    private func modeCard(_ m: Mode, icon: String, title: String, badge: String, badgeColor: Color, detail: String) -> some View {
        let isOn = mode == m
        return Button {
            modeRaw = m.rawValue
            if m == .shrink { store.shrink.options.enabled = true }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isOn ? Theme.onSweep : Theme.sweep)
                    .frame(width: 36, height: 36)
                    .background(isOn ? Theme.sweep : Theme.mintTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title).font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                        BadgeView(text: badge, color: badgeColor)
                    }
                    Text(detail)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Circle()
                    .strokeBorder(isOn ? Theme.sweep : Theme.controlBorder, lineWidth: 1.5)
                    .overlay { if isOn { Circle().fill(Theme.sweep).frame(width: 8, height: 8) } }
                    .frame(width: 16, height: 16)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(isOn ? Theme.sweep : Theme.border, lineWidth: isOn ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
    }

    /// Shown above the Shrink section when Shrink is the chosen mode (CompressModes board).
    private var shrinkIntro: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.warning)
                .frame(width: 32, height: 32)
                .background(Theme.warningTint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            (Text("Shrink lowers quality.").fontWeight(.semibold).foregroundColor(Theme.ink)
             + Text(" Photos, videos and PDFs are re-encoded smaller. You see a before/after preview, and originals go to the Trash.")
                .foregroundColor(Theme.inkTertiary))
                .font(Theme.body)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Compress")
                .font(.largeTitle.weight(.semibold))
            Text("Smaller files, identical content. Each result is checked pixel for pixel or byte for byte before it replaces the original.")
                .foregroundStyle(.secondary)
        }
    }

    private var scanningState: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.regular)
            Text(store.phase.isEmpty ? "Looking for savings…" : store.phase)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 420)
            Text("Nothing found yet · \(store.scannedFileCount.formatted()) files checked")
                .font(Theme.caption.monospacedDigit())
                .foregroundStyle(Theme.inkSecondary)
            ScanStripBar(fraction: store.live?.fraction)
                .frame(width: 220)
                .clipShape(Capsule())
            CancelRunButton(compact: true) { store.cancel() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var heroCard: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(store.isScanning ? "Without deleting anything, you can save about (so far)" : "Without deleting anything, you can save about")
                    .font(Theme.body)
                    .foregroundStyle(Theme.inkSecondary)
                Text(FileSizeHelper.formatBytes(store.estimatedSavingsBytes))
                    .font(.system(size: 40, weight: .semibold))
                    .tracking(-0.5)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                Text(countsLine)
                    .font(Theme.body)
                    .foregroundStyle(Theme.inkSecondary)
                if store.isScanning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(store.phase).font(Theme.micro).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                    }
                } else {
                    Button("Scan again") { Task { await store.scan() } }
                        .buttonStyle(SweepLinkStyle())
                        .font(Theme.micro)
                        .disabled(store.isBusy)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Toggle("Only files not opened in", isOn: $store.options.onlyUnused)
                    SweepMenuPicker(options: [7, 30, 60, 90, 180, 365], selection: $store.options.minDaysUnused) { "\($0) days" }
                }
                Toggle("Keep originals in the Trash for 30 days", isOn: $store.options.keepOriginalsInTrash)
                Toggle(isOn: $store.options.stripPhotoMetadata) {
                    HStack(spacing: 6) {
                        Text("Also strip photo location and camera data")
                        BadgeView(text: "Not lossless", color: Theme.warning,
                                  help: "Removes GPS and camera EXIF from photos. Pixels are still verified, but that metadata is gone.")
                    }
                }
                if store.folderScanIsStale {
                    Label("Folders will be re-checked for the new age limit when you start.", systemImage: "arrow.clockwise")
                        .font(Theme.micro)
                        .foregroundStyle(Theme.inkSecondary)
                }
                Button {
                    showConfirm = true
                } label: {
                    Text("Compress \(FileSizeHelper.formatBytes(store.estimatedSavingsBytes))")
                        .frame(minWidth: 160)
                }
                .buttonStyle(SweepButtonStyle(kind: .primary, height: 36))
                .fixedSize()
                .disabled(store.isBusy || store.eligibleCandidates.isEmpty)
                .padding(.top, 4)
            }
            .font(Theme.caption)
            .toggleStyle(.furlCheckbox)
            .disabled(store.isRunning)
        }
        .card(padding: 20)
    }

    private var countsLine: String {
        let files = store.eligibleFileCount
        let folders = store.eligibleFolderCount
        return "\(files.formatted()) file\(files == 1 ? "" : "s") and \(folders.formatted()) folder\(folders == 1 ? "" : "s")"
    }

    private func categoryCard(_ category: CompressCategory) -> some View {
        let summary = store.summary(for: category)
        let available = summary?.available ?? true
        let enabled = store.isEnabled(category) && available
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { enabled },
                    set: { store.setCategory(category, enabled: $0) }
                )) {
                    HStack(spacing: 8) {
                        Image(systemName: category.systemImage)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.inkSecondary)
                            .frame(width: 15)
                        Text(category.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                    }
                }
                .toggleStyle(.furlCheckbox)
                .disabled(!available || store.isRunning)
                Spacer()
                if available && store.isEstimatePending(category) {
                    Text(store.isScanning ? "Measuring…" : "Not measured")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkSecondary)
                } else {
                    Text(available ? FileSizeHelper.formatBytes(summary?.estimatedSavings ?? 0) : "—")
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                }
            }
            Text(category.summary)
                .font(Theme.caption)
                .foregroundStyle(Theme.inkSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if let summary {
                    Button {
                        listedCategory = category
                    } label: {
                        Text("\(summary.method) · \(summary.count.formatted()) \(category.unitName)")
                    }
                    .buttonStyle(SweepLinkStyle())
                    .disabled(summary.count == 0)
                    .help("Show what would be compressed")
                }
                if category.changesFileType {
                    BadgeView(text: "Changes file type", color: Theme.warning)
                }
                Spacer()
                if let note = summary?.note {
                    Text(note)
                        .font(Theme.micro)
                        .foregroundStyle(available ? Theme.inkSecondary : Theme.warning)
                        .textSelection(.enabled)
                    if !available, let tool = requiredTool(category) {
                        Text("·").font(Theme.micro).foregroundStyle(Theme.warning)
                        Button("Install \(tool.binaryName)") { installRequired(tool) }
                            .buttonStyle(SweepLinkStyle())
                            .font(Theme.micro.weight(.semibold))
                            .disabled(installer.isRunning || store.isBusy)
                    }
                }
            }
            .font(Theme.micro)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .card(padding: 0)
        .opacity(!available ? 0.6 : (enabled ? 1 : 0.7))
    }

    /// What each category is estimated to save right now (0 when it can't run).
    private func categorySavings() -> [CompressCategory: Int64] {
        Dictionary(uniqueKeysWithValues: CompressCategory.allCases.map { category in
            let summary = store.summary(for: category)
            return (category, summary?.available == true ? summary?.estimatedSavings ?? 0 : 0)
        })
    }

    /// Before/after for only the categories the newly installed tools work on.
    private var estimateChange: (categories: [CompressCategory], before: Int64, after: Int64)? {
        guard let before = estimateBeforeInstall else { return nil }
        let installed = Set(OptionalTool.lossless.filter { installer.state($0) == .installed }.compactMap(\.compressCategory))
        let categories = CompressCategory.allCases.filter { installed.contains($0) }
        guard !categories.isEmpty else { return nil }
        let now = categorySavings()
        return (categories, categories.reduce(0) { $0 + (before[$1] ?? 0) }, categories.reduce(0) { $0 + (now[$1] ?? 0) })
    }

    private func closeToolResult() {
        installer.reset()
        estimateBeforeInstall = nil
        toolResultShown = false
    }

    /// The tool a category can't run without.
    private func requiredTool(_ category: CompressCategory) -> OptionalTool? {
        switch category {
        case .pdfs: return .qpdf
        case .jpeg: return .jpegTurbo
        default: return nil
        }
    }

    /// The quiet way back after "Not now": install straight from the category card.
    private func installRequired(_ tool: OptionalTool) {
        dismissedToolsRaw = dismissedTools.subtracting([tool]).map(\.rawValue).sorted().joined(separator: ",")
        if ToolInstaller.brewPath != nil {
            installer.install([tool])
        } else if store.toolFinds[tool] == nil, let url = URL(string: "https://brew.sh") {
            NSWorkspace.shared.open(url)
        }
    }

    private var skippedNote: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 14)
                    .padding(.top, 2)
                skippedText
                    .font(Theme.caption)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .tint(Theme.sweep)
                    .environment(\.openURL, OpenURLAction { _ in
                        showSkipped.toggle()
                        return .handled
                    })
            }
            .padding(.bottom, showSkipped ? 8 : 0)
            if showSkipped {
                ForEach(store.skipped) { group in
                    HStack(spacing: 8) {
                        Text(group.reason)
                            .foregroundStyle(Theme.inkTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(group.count.formatted()) · \(FileSizeHelper.formatBytes(group.bytes))")
                            .monospacedDigit()
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    .font(Theme.caption)
                    .padding(.vertical, 5)
                    .padding(.leading, 22)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                }
                let tools = store.tools.installedNames
                Text(tools.isEmpty
                     ? "Works offline with built-in macOS tools. Optional Homebrew tools (oxipng, zopflipng, gifsicle, jpegtran, qpdf) unlock more formats."
                     : "Works offline. Using installed tools: \(tools.joined(separator: ", ")).")
                    .font(Theme.micro)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 0)
    }

    /// The skipped note with its inline "Skipped, and why" / "Hide details" link (CompressStates board).
    private var skippedText: Text {
        var lead = AttributedString("Skipped:")
        lead.foregroundColor = Theme.ink
        lead.font = .system(size: 12, weight: .semibold)
        var body = AttributedString(" videos, MP3, AAC and files that are already compressed. Making these smaller means losing quality, so Furl leaves them alone here. Switch to Shrink if you're happy to trade quality for space, or use Large Files to decide about them.")
        body.foregroundColor = Theme.inkTertiary
        var text = lead + body
        if !store.skipped.isEmpty {
            var link = AttributedString(showSkipped ? "Hide details" : "Skipped, and why")
            link.link = URL(string: "furl-internal://compress-skipped")
            link.foregroundColor = Theme.sweep
            link.font = .system(size: 12, weight: .medium)
            text += AttributedString(" ") + link
        }
        return Text(text)
    }

    private var runningCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Compressing \(store.processedCount.formatted()) of \(store.totalCount.formatted())")
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("Saved \(FileSizeHelper.formatBytes(store.savedSoFar))")
                    .monospacedDigit()
                    .foregroundStyle(Theme.sweep)
            }
            .font(Theme.bodyStrong)
            MeterBar(fraction: store.progressFraction, color: Theme.sweep, track: Theme.sweep.opacity(0.18), height: 6)
            HStack(spacing: 8) {
                Text(store.phase)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CancelRunButton(compact: true) { store.cancel() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .card(padding: 0)
    }

    private func resultsCard(_ run: CompressRunResult) -> some View {
        let compressed = run.count(.compressed)
        let kept = run.count(.notSmaller)
        let skipped = run.count(.skipped)
        let rejected = run.count(.rejected) + run.count(.failed)
        let notable = run.items.filter { $0.status == .rejected || $0.status == .failed || $0.status == .skipped }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 13, weight: .semibold))
                Text(run.wasCancelled ? "Stopped" : "Done")
                    .font(Theme.bodyStrong)
            }
            .foregroundStyle(Theme.sweep)
            HStack(spacing: 8) {
                Text("Saved \(FileSizeHelper.formatBytes(run.savedBytes))")
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                Spacer()
                if run.originalsKeptInTrash && compressed > 0 {
                    Button("Undo") { Task { await store.undoLastRun() } }
                        .buttonStyle(SweepButtonStyle(kind: .secondary, height: 28))
                        .font(Theme.caption)
                        .fixedSize()
                }
                Button("Dismiss") { store.dismissResults() }
                    .buttonStyle(SweepButtonStyle(kind: .secondary, height: 28))
                    .font(Theme.caption)
                    .fixedSize()
            }
            Text("\(compressed.formatted()) compressed and verified · \(kept.formatted()) already as small as possible · \(skipped.formatted()) skipped · \(rejected.formatted()) left alone after a failed check")
                .font(Theme.caption)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if run.originalsKeptInTrash && compressed > 0 {
                Text("Originals are in the Trash. The space is freed when the Trash is emptied (macOS does this after 30 days if that Finder setting is on).")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !notable.isEmpty {
                CompressDisclosure(title: "Skipped, and why (\(notable.count.formatted()))") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(notable.prefix(200)) { item in
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.name).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(item.message).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                            }
                            .font(Theme.caption)
                            .pathContextMenu(item.path)
                        }
                    }
                    .padding(.leading, 16)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .card(padding: 0)
    }

    private func undoBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.sweep)
            Text(text)
                .font(Theme.body)
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss") { store.dismissResults() }
                .buttonStyle(SweepButtonStyle(kind: .secondary, height: 28))
                .font(Theme.caption)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .card(padding: 0)
    }

    // MARK: Confirmation

    private var confirmTitle: String {
        "Compress about \(FileSizeHelper.formatBytes(store.estimatedSavingsBytes))?"
    }

    private var confirmMessage: String {
        var lines = ["Each file is checked to be identical before it replaces the original. Files that are open, iCloud-only or not smaller are left alone."]
        lines.append(store.options.keepOriginalsInTrash
                     ? "Originals go to the Trash, so you can undo."
                     : "Originals will be deleted permanently once each copy is verified. This can't be undone.")
        if store.isEnabled(.audio) { lines.append("WAV and AIFF files will become Apple Lossless .m4a files.") }
        if store.options.stripPhotoMetadata { lines.append("Photo location and camera data will be removed.") }
        return lines.joined(separator: "\n\n")
    }
}

/// Lists what a category would compress (CompressStates board: candidate sheet).
private struct CandidateListSheet: View {
    let category: CompressCategory
    let items: [CompressCandidate]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: category.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text(category.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        row(item)
                    }
                }
            }
        }
        .background(Theme.surface)
        .frame(minWidth: 620, minHeight: 420)
    }

    private func row(_ item: CompressCandidate) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.isApp ? "app" : category.systemImage)
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(Theme.body)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text((item.path as NSString).abbreviatingWithTildeInPath)
                    .font(Theme.micro)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let used = item.lastUsed {
                Text("Last used \(used.formatted(.dateTime.day().month(.abbreviated).year()))")
                    .font(Theme.micro)
                    .foregroundStyle(Theme.inkSecondary)
            }
            Text(FileSizeHelper.formatBytes(item.sizeBytes))
                .font(Theme.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .contentShape(Rectangle())
        .pathContextMenu(item.path)
    }
}

/// Chevron disclosure used by the Compress results ("Skipped, and why (n)").
private struct CompressDisclosure<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(width: 10)
                    Text(title)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.ink)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen { content() }
        }
    }
}
