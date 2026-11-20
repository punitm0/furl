import AppKit
import SwiftUI

/// Opt-in lossy Shrink panel shown under the lossless Compress cards.
struct ShrinkSection: View {
    @ObservedObject var store: ShrinkStore
    /// True while the lossless Compress run or scan is busy; the two never run at once.
    var compressIsBusy: Bool
    /// False when the Compress screen's mode chooser already picked Shrink: no on/off switch.
    var showsToggle = true
    @State private var showPreview = false
    @State private var showSkipped = false
    @State private var showRisks = false
    @State private var showNotShrunk = false
    @State private var tab: Tab = .shrink
    @ObservedObject private var installer = ToolInstaller.shared

    private enum Tab: String, CaseIterable, Identifiable {
        case shrink = "Shrink", formats = "Format suggestions"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if store.options.enabled {
                warning
                PillTabs(tabs: Tab.allCases, selection: $tab) { $0.rawValue }
                .fixedSize()
                .disabled(store.isRunning || store.formats.isRunning)
                if tab == .formats {
                    FormatSuggestionsPanel(store: store.formats, shrink: store, compressIsBusy: compressIsBusy)
                } else {
                if store.isRunning {
                    runningRow
                } else if let run = store.lastRun {
                    results(run)
                } else if let undo = store.lastUndoSummary {
                    ShrinkUndoRow(text: undo) { store.dismissResults() }
                }
                scope
                LiveScanStripSlot(status: store.live, onStop: { store.cancel() },
                                  onRescan: { Task { await store.scan() } })
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                if store.hasScanned {
                    kinds
                    recentRow
                    photoDetailsRow
                    optionalTools
                    estimateRow
                    ShrinkRatioColumns(ratio: 1.6, spacing: 20) {
                        skipped.frame(maxWidth: .infinity, alignment: .leading)
                        risks.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 14)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                } else {
                    if store.isScanning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(store.phase.isEmpty ? "Looking for photos, videos and PDFs…" : store.phase)
                                .font(Theme.body).foregroundStyle(Theme.inkSecondary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            CancelRunButton(compact: true) { store.cancel() }
                        }
                    }
                    risks
                }
                }
            }
        }
        .font(Theme.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 18)
        .sheet(isPresented: $showPreview) {
            ShrinkPreviewSheet(store: store)
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var header: some View {
        if showsToggle { toggleHeader }
    }

    private var toggleHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle(isOn: $store.options.enabled) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text("Shrink")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        ShrinkCapsBadge(text: "LOWERS QUALITY", fg: Theme.warning, bg: Theme.warningTint)
                            .help("Shrink re-encodes files at a lower quality. It is not lossless.")
                    }
                    if !store.options.enabled {
                        Text("Optional. Re-encodes photos, videos and the images inside PDFs at a lower quality, to save far more space than lossless compression can.")
                            .font(Theme.body)
                            .foregroundStyle(Theme.inkSecondary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.sweep)
            .disabled(store.isRunning)
            Spacer(minLength: 0)
        }
    }

    private var warning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.warning)
                .padding(.top, 1)
            (Text("This lowers quality.").fontWeight(.bold)
             + Text(" Shrunk files are not identical to the originals. Originals go to the Trash, so you can undo until the Trash is emptied. After that, the lost quality can't be brought back."))
                .font(Theme.body)
                .lineSpacing(2)
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warningTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var scope: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSecondary)
            scopeLabel
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Choose Folder…") { chooseFolder() }
                .buttonStyle(SweepLinkStyle())
                .disabled(store.isBusy)
            if store.roots != ShrinkService.defaultRoots() {
                Button("Use home folder") {
                    store.roots = ShrinkService.defaultRoots()
                    Task { await store.scan() }
                }
                .buttonStyle(SweepLinkStyle())
                .disabled(store.isBusy)
            }
            Spacer()
            if !store.hasScanned && !store.isScanning {
                Button("Find Files to Shrink") { Task { await store.scan() } }
                    .buttonStyle(SweepButtonStyle(kind: .primary))
                    .fixedSize()
                    .disabled(store.isBusy || compressIsBusy)
            } else if store.hasScanned {
                Button("Scan again") { Task { await store.scan() } }
                    .buttonStyle(SweepLinkStyle())
                    .font(Theme.caption)
                    .disabled(store.isBusy || compressIsBusy)
            }
        }
        .font(Theme.body)
    }

    private var scopeLabel: Text {
        let lead = Text("Looking in ").foregroundColor(Theme.inkTertiary)
        if store.roots == ShrinkService.defaultRoots() {
            return lead + Text("~").fontWeight(.semibold).foregroundColor(Theme.ink)
                + Text(" (your home folder)").foregroundColor(Theme.inkTertiary)
        }
        return lead + Text(store.rootsLabel).fontWeight(.semibold).foregroundColor(Theme.ink)
    }

    // MARK: Kinds (ShrinkOn board: one card per kind with its own settings)

    private var kinds: some View {
        HStack(alignment: .top, spacing: 10) {
            kindCard(.photos) {
                sliderRow("Quality", value: $store.options.imageQuality)
                Picker("Save photos as", selection: $store.options.imageFormat) {
                    ForEach(ShrinkImageFormat.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .help("HEIC is smaller than JPEG. Choosing it changes JPEG files to .heic.")
                HStack(spacing: 8) {
                    Text("Largest side").foregroundStyle(Theme.inkTertiary)
                    Spacer(minLength: 0)
                    FurlPopUp("Largest side", selection: $store.options.maxImageDimension, value: store.options.maxImageDimension.map { "Up to \($0) px" } ?? "Original size") {
                        Text("Original size").tag(Int?.none)
                        ForEach([6000, 4096, 3072, 2048], id: \.self) { Text("Up to \($0) px").tag(Int?.some($0)) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            kindCard(.videos) {
                HStack(spacing: 8) {
                    Text("Size").foregroundStyle(Theme.inkTertiary)
                    Spacer(minLength: 0)
                    FurlPopUp("Size", selection: $store.options.videoPreset, value: videoSizeTitle(store.options.videoPreset)) {
                        ForEach([ShrinkVideoPreset.hd1080, .uhd4K, .highest]) { Text(videoSizeTitle($0)).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
                Text("Up to 1080p saves the most and is plenty for a laptop screen. Original size saves the least.")
                    .foregroundStyle(Theme.inkSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            kindCard(.pdfs) {
                Text("Only the pictures change. Text, links and pages stay exactly as they are.")
                    .foregroundStyle(Theme.inkSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(store.isRunning)
    }

    private func videoSizeTitle(_ preset: ShrinkVideoPreset) -> String {
        switch preset {
        case .hd1080: return "Up to 1080p"
        case .uhd4K: return "Up to 4K"
        case .highest: return "Original size"
        }
    }

    private func kindCard<Settings: View>(_ kind: ShrinkKind, @ViewBuilder settings: () -> Settings) -> some View {
        let isOn = store.options.kinds.contains(kind)
        return VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { isOn }, set: { store.setKind(kind, enabled: $0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.title).font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                    Text(isOn ? "\(kind.count(store.eligible(kind).count)) · \(FileSizeHelper.formatBytes(store.bytes(kind)))" : "Off")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            .toggleStyle(.furlCheckbox)
            VStack(alignment: .leading, spacing: 10) {
                settings()
            }
            .font(Theme.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private func sliderRow(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundStyle(Theme.inkTertiary)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
            }
            Slider(value: value, in: 0.4...0.95, step: 0.05)
                .controlSize(.small)
                .tint(Theme.sweep)
        }
    }

    /// Not on the ShrinkOn board; kept so the recent-files rule can still be changed.
    private var recentRow: some View {
        HStack(spacing: 8) {
            Text("Skip files changed in").foregroundStyle(Theme.inkSecondary)
            FurlPopUp("Skip files changed in", selection: $store.options.recentDays, value: "the last \(store.options.recentDays) days") {
                ForEach([7, 30, 90, 365], id: \.self) { Text("the last \($0) days").tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .font(Theme.caption)
        .disabled(store.isRunning)
    }

    /// Only photos that were replaced lose their details; the rest keep the original file untouched.
    private func photoDetailsLine(_ run: ShrinkRunResult) -> String {
        func photos(_ n: Int) -> String { "\(n.formatted()) photo\(n == 1 ? "" : "s")" }
        var line = "Location and camera details removed from \(photos(run.shrunkPhotoCount))."
        if run.unshrunkPhotoCount > 0 { line += " \(photos(run.unshrunkPhotoCount)) left as they were." }
        return line
    }

    /// CompressSimple: moved here from Lossless, which promises identical files. Shrink already rewrites photos.
    private var photoDetailsRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Also remove photo location and camera details", isOn: $store.options.stripPhotoMetadata)
                .toggleStyle(.furlCheckbox)
                .font(Theme.caption)
                .accessibilityHint("Where and with what each photo was taken. Off by default.")
            Text("Where and with what each photo was taken. Off by default.")
                .font(Theme.micro)
                .foregroundStyle(Theme.inkSecondary)
                .padding(.leading, 22)
                .accessibilityHidden(true)
        }
        .disabled(store.isRunning)
    }

    // MARK: Optional tools

    private var optionalTools: some View {
        VStack(alignment: .leading, spacing: 8) {
            (Text("Optional tools").fontWeight(.semibold).foregroundColor(Theme.inkTertiary)
             + Text(" · Free Homebrew tools. Furl installs them only when you click Install, with no admin password.")
                .foregroundColor(Theme.inkSecondary))
                .font(Theme.caption)
            HStack(alignment: .top, spacing: 10) {
                toolCard(name: "Lossy PNG", tool: .pngquant, installed: store.options.tools.pngquant != nil,
                         detail: OptionalTool.pngquant.detail,
                         command: "brew install pngquant") {
                    Toggle(isOn: Binding(get: { store.options.kinds.contains(.png) },
                                         set: { store.setKind(.png, enabled: $0) })) {
                        Text("Shrink \(ShrinkKind.png.title)")
                            + Text(store.options.kinds.contains(.png) ? " · \(ShrinkKind.png.count(store.eligible(.png).count))" : "")
                                .foregroundColor(Theme.inkSecondary)
                    }
                    .toggleStyle(.furlCheckbox)
                }
                toolCard(name: "Keep as JPEG", tool: .mozjpeg, installed: store.options.tools.mozjpeg != nil,
                         detail: OptionalTool.mozjpeg.detail,
                         command: "brew install mozjpeg") {
                    EmptyView()
                }
            }
        }
        .disabled(store.isRunning)
    }

    private func toolCard<Installed: View>(name: String, tool: OptionalTool, installed: Bool, detail: String, command: String,
                                           @ViewBuilder whenInstalled: () -> Installed) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                (Text(name).fontWeight(.semibold).foregroundColor(Theme.ink)
                 + Text(" · \(tool == .mozjpeg ? "MozJPEG" : tool.binaryName)").foregroundColor(Theme.inkSecondary))
                    .font(Theme.body)
                Spacer(minLength: 0)
                if installed {
                    ShrinkCapsBadge(text: "INSTALLED", fg: Theme.sweep, bg: Theme.mintTint)
                } else {
                    ShrinkCapsBadge(text: "NOT INSTALLED", fg: Theme.inkTertiary, bg: Theme.hairline)
                }
            }
            Text(detail)
                .font(Theme.caption)
                .foregroundStyle(Theme.inkSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if installed {
                whenInstalled()
                    .font(Theme.caption)
            } else if installer.state(tool) == .installing || installer.state(tool) == .waiting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                    Text(installer.state(tool) == .waiting ? "Waiting for Homebrew…" : "Installing with Homebrew…")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkTertiary)
                    Spacer(minLength: 0)
                    CancelRunButton(compact: true) { installer.cancel() }
                }
                .frame(minHeight: 28)
            } else {
                if let find = store.toolFind(tool) {
                    Text("This scan found \(find.countText) · \(FileSizeHelper.formatBytes(find.bytes))")
                        .font(Theme.caption.monospacedDigit())
                        .foregroundStyle(Theme.inkTertiary)
                }
                if installer.state(tool) == .failed {
                    Text(installer.lastError ?? "Homebrew couldn't install it.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.danger)
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if ToolInstaller.brewPath == nil {
                    HStack(spacing: 4) {
                        Text("Needs Homebrew, which isn't installed.")
                        Button("Open brew.sh") { if let url = URL(string: "https://brew.sh") { NSWorkspace.shared.open(url) } }
                            .buttonStyle(SweepLinkStyle())
                    }
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
                }
                HStack(spacing: 8) {
                    Text(command)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .background(Theme.hairline, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .buttonStyle(SweepButtonStyle(kind: .secondary, height: 28))
                    .font(Theme.caption)
                    .fixedSize()
                    if ToolInstaller.brewPath != nil {
                        Button(installer.state(tool) == .failed ? "Try Again" : "Install") { installer.install([tool]) }
                            .buttonStyle(SweepButtonStyle(kind: .primary, height: 28))
                            .font(Theme.caption.weight(.semibold))
                            .fixedSize()
                            .disabled(installer.isRunning)
                    } else {
                        Button("Check Again") { store.refreshTools() }
                            .buttonStyle(SweepButtonStyle(kind: .secondary, height: 28))
                            .font(Theme.caption)
                            .fixedSize()
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private var estimateRow: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("About")
                        .foregroundStyle(Theme.inkSecondary)
                    Text(FileSizeHelper.formatBytes(store.estimatedSavingsBytes))
                        .font(Theme.display(26))
                        .tracking(-0.5)
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                    Text("smaller across \(store.eligible.count.formatted()) file\(store.eligible.count == 1 ? "" : "s")")
                        .foregroundStyle(Theme.inkSecondary)
                }
                if store.isScanning {
                    Text("Still scanning. The estimate is measured on a sample once the scan finishes.")
                        .font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                } else if store.isEstimating {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(store.phase.isEmpty ? "Measuring on a sample…" : store.phase)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                } else if store.estimateIsStale {
                    Button("Settings changed. Re-measure the estimate") { Task { await store.estimate() } }
                        .buttonStyle(SweepLinkStyle())
                        .font(Theme.caption)
                } else {
                    Text("Measured by shrinking a small sample in a temporary folder. Files that wouldn't get at least \(Int(store.options.minimumSavingsFraction * 100))% smaller keep their original.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button("Preview & Shrink…") {
                showPreview = true
            }
            .buttonStyle(SweepButtonStyle(kind: .warning, height: 36))
            .fixedSize()
            .disabled(store.isBusy || compressIsBusy || store.eligible.isEmpty || store.live?.phase == .stopped)
            .help(store.live?.phase == .stopped ? "The scan was stopped. Scan again to shrink." : "")
        }
        .padding(.top, 4)
    }

    private var skipped: some View {
        let groups = store.skipGroups
        let allowed = store.options.allowedFolders.sorted()
        let total = groups.reduce(0) { $0 + $1.count }
        return VStack(alignment: .leading, spacing: 8) {
            if !groups.isEmpty || !allowed.isEmpty {
                sectionToggle(isOpen: $showSkipped) {
                    Text("Skipped by default") + Text(" · \(total.formatted()) file\(total == 1 ? "" : "s")")
                        .fontWeight(.regular).foregroundColor(Theme.inkSecondary)
                }
                if showSkipped {
                    VStack(spacing: 0) {
                        ForEach(Array(groups.prefix(120).enumerated()), id: \.element.id) { i, group in
                            skipRow(group)
                                .overlay(alignment: .top) {
                                    if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                                }
                        }
                        if !allowed.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(allowed, id: \.self) { folder in
                                    HStack(spacing: 8) {
                                        Text("Allowed").fontWeight(.semibold).foregroundStyle(Theme.ink)
                                        Text((folder as NSString).abbreviatingWithTildeInPath)
                                            .foregroundStyle(Theme.inkTertiary)
                                            .lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Button("Remove") { store.disallow(folder: folder) }
                                            .buttonStyle(SweepLinkStyle())
                                    }
                                }
                            }
                            .font(Theme.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.surfaceSubtle)
                            .overlay(alignment: .top) {
                                if !groups.isEmpty { Rectangle().fill(Theme.hairline).frame(height: 1) }
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                }
            }
        }
        .disabled(store.isRunning)
    }

    private func skipRow(_ group: ShrinkSkipGroup) -> some View {
        HStack(spacing: 10) {
            Image(systemName: skipIcon(group.reason))
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(group.reason == .photosLibrary ? "Photos library" : (group.folder as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1).truncationMode(.middle)
                Text(skipDetail(group.reason))
                    .font(Theme.micro)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if group.reason != .photosLibrary {
                Text("\(group.count.formatted()) · \(FileSizeHelper.formatBytes(group.bytes))")
                    .font(Theme.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkTertiary)
            }
            Group {
                if group.reason.allowable {
                    Button("Allow Folder") { store.allow(folder: group.folder) }
                        .buttonStyle(SweepButtonStyle(kind: .secondary, height: 28))
                        .font(Theme.caption)
                        .fixedSize()
                        .help("Shrink files in this folder even though they are \(group.reason == .cloudSynced ? "cloud-synced" : "recently changed")")
                } else if let note = skipTrailing(group.reason) {
                    Text(note).font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                }
            }
            .frame(width: 104, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .pathContextMenu(group.folder, allowOpen: false)
    }

    private func skipIcon(_ reason: ShrinkSkipReason) -> String {
        switch reason {
        case .photosLibrary: return "lock"
        case .cloudSynced: return "cloud"
        case .openInApp: return "display"
        case .recentlyModified: return "clock"
        case .alreadyShrunk: return "arrow.down.right.and.arrow.up.left"
        }
    }

    private func skipDetail(_ reason: ShrinkSkipReason) -> String {
        switch reason {
        case .photosLibrary: return "Never touched: editing it would damage the library"
        case .cloudSynced: return "Synced: the smaller copy would replace it everywhere"
        case .openInApp: return "Checked again on the next scan"
        case .recentlyModified: return "Changed in the last \(store.options.recentDays) days"
        case .alreadyShrunk: return reason.title
        }
    }

    private func skipTrailing(_ reason: ShrinkSkipReason) -> String? {
        switch reason {
        case .photosLibrary: return "Always skipped"
        case .openInApp: return "While open"
        default: return nil
        }
    }

    private var risks: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionToggle(isOpen: $showRisks) { Text("Risks") }
            if showRisks {
                VStack(alignment: .leading, spacing: 7) {
                    riskRow("Quality loss", "Fine detail and smooth gradients get simpler. Check the preview at 100%.")
                    riskRow("Each re-encode loses more", "Furl won't shrink a file twice; other apps might.")
                    riskRow("Metadata", "Location, dates and colour profile are kept. Rare maker notes and video chapters may not be.")
                    riskRow("Other apps", "Lightroom or sync tools may re-import or re-upload a changed file.")
                    riskRow("Cloud folders", "Skipped unless you allow them, because the copy on every device changes.")
                }
            }
        }
    }

    private func sectionToggle(isOpen: Binding<Bool>, @ViewBuilder label: () -> Text) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isOpen.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOpen.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 12)
                label().fontWeight(.semibold).foregroundColor(Theme.ink)
            }
            .font(Theme.body)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func riskRow(_ title: String, _ text: String) -> some View {
        (Text(title + ". ").fontWeight(.semibold).foregroundColor(Theme.ink) + Text(text).foregroundColor(Theme.inkSecondary))
            .font(Theme.caption)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var runningRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Shrinking \(store.processedCount.formatted()) of \(store.totalCount.formatted())")
                Spacer()
                Text("Saved \(FileSizeHelper.formatBytes(store.savedSoFar))")
                    .monospacedDigit()
            }
            .font(Theme.bodyStrong)
            .foregroundStyle(Theme.ink)
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

    private func results(_ run: ShrinkRunResult) -> some View {
        let shrunk = run.count(.shrunk)
        let kept = run.count(.keptOriginal)
        let skipped = run.count(.skipped)
        let failed = run.count(.failed)
        let notable = run.items.filter { $0.status != .shrunk }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Label(run.wasCancelled ? "Stopped" : "Shrunk", systemImage: "arrow.down.right.and.arrow.up.left")
                    .labelStyle(ShrinkTightLabel())
                    .font(Theme.bodyStrong)
                    .foregroundStyle(Theme.warning)
                Text("Saved \(FileSizeHelper.formatBytes(run.savedBytes))")
                    .font(Theme.display(18))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                if run.originalBytesOfShrunk > 0 {
                    Text("\(Int((Double(run.savedBytes) / Double(run.originalBytesOfShrunk) * 100).rounded()))% of those files")
                        .foregroundStyle(Theme.inkSecondary)
                }
                Spacer()
                Button("Dismiss") { store.dismissResults() }
                    .buttonStyle(SweepButtonStyle(kind: .secondary, height: 28))
                    .font(Theme.caption)
                    .fixedSize()
                if shrunk > 0 {
                    Button("Undo") { Task { await store.undoLastRun() } }
                        .buttonStyle(SweepButtonStyle(kind: .primary, height: 28))
                        .font(Theme.caption)
                        .fixedSize()
                }
            }
            Text("\(shrunk.formatted()) shrunk at lower quality · \(kept.formatted()) kept as is (less than \(Int(store.options.minimumSavingsFraction * 100))% smaller) · \(skipped.formatted()) skipped · \(failed.formatted()) failed")
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if run.removedPhotoDetails, run.shrunkPhotoCount + run.unshrunkPhotoCount > 0 {
                Text(photoDetailsLine(run))
                    .foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if shrunk > 0 || !notable.isEmpty {
                HStack(spacing: 8) {
                    if shrunk > 0 {
                        Image(systemName: "trash").font(.system(size: 11))
                        Text("Originals are in the Trash at full quality. Undo, or put them back from the Trash, until it's emptied.")
                    }
                    Spacer(minLength: 8)
                    if !notable.isEmpty {
                        Button("Not shrunk, and why (\(notable.count.formatted()))") { showNotShrunk.toggle() }
                            .buttonStyle(SweepLinkStyle())
                    }
                }
                .font(Theme.caption)
                .foregroundStyle(Theme.inkSecondary)
            }
            if showNotShrunk && !notable.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(notable.prefix(200)) { item in
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(item.message).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                        }
                        .font(Theme.caption)
                        .pathContextMenu(item.path)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Look Here"
        panel.message = "Choose folders to look for photos, videos and PDFs to shrink."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        store.roots = panel.urls.map { $0.standardizedFileURL.path }
        Task { await store.scan() }
    }
}

/// Quality settings in the preview sheet (ShrinkPreview board: image quality and video rows).
struct ShrinkSettingsControls: View {
    @ObservedObject var store: ShrinkStore

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Image quality").foregroundStyle(Theme.inkSecondary)
                    .frame(width: 90, alignment: .leading)
                    .help("Used for photos and for images inside PDFs")
                HStack(spacing: 10) {
                    Slider(value: $store.options.imageQuality, in: 0.4...0.95, step: 0.05)
                        .controlSize(.small)
                        .tint(Theme.sweep)
                        .frame(width: 220)
                    Text("\(Int((store.options.imageQuality * 100).rounded()))%")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                    FurlPopUp("Format", selection: $store.options.imageFormat, value: store.options.imageFormat.title) {
                        ForEach(ShrinkImageFormat.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .help("HEIC is smaller than JPEG. Choosing it changes JPEG files to .heic.")
                    FurlPopUp("Largest side", selection: $store.options.maxImageDimension, value: store.options.maxImageDimension.map { "Up to \($0) px" } ?? "Original size") {
                        Text("Original size").tag(Int?.none)
                        ForEach([6000, 4096, 3072, 2048], id: \.self) { Text("Up to \($0) px").tag(Int?.some($0)) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            GridRow {
                Text("Video").foregroundStyle(Theme.inkSecondary)
                FurlPopUp("Video", selection: $store.options.videoPreset, value: store.options.videoPreset.title) {
                    ForEach(ShrinkVideoPreset.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
        }
        .font(Theme.caption)
        .disabled(store.isRunning)
    }
}

/// Before/after comparison shown before anything is shrunk.
struct ShrinkPreviewSheet: View {
    @ObservedObject var store: ShrinkStore
    @Environment(\.dismiss) private var dismiss
    @State private var showDetail = false
    /// "How ▸" next to the quality label: the measured number and the encoder settings.
    @State private var showHow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Preview Shrink").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                ShrinkCapsBadge(text: "LOWERS QUALITY", fg: Theme.warning, bg: Theme.warningTint)
                Spacer()
                FurlPopUp("File to preview", selection: Binding(
                    get: { store.previewTarget?.path ?? "" },
                    set: { path in
                        if let item = store.eligible.first(where: { $0.path == path }) {
                            Task { await store.loadPreview(for: item) }
                        }
                    }
                ), value: store.previewTarget.map { "\($0.name) · \(FileSizeHelper.formatBytes($0.sizeBytes))" } ?? "Choose a file") {
                    ForEach(ShrinkKind.allCases) { kind in
                        let items = store.eligible(kind).prefix(40)
                        if !items.isEmpty {
                            Section(kind.title) {
                                ForEach(items) { item in
                                    Text("\(item.name) · \(FileSizeHelper.formatBytes(item.sizeBytes))").tag(item.path)
                                }
                            }
                        }
                    }
                }
                .labelsHidden()
                .font(Theme.caption)
                .frame(width: 300)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 12) {
                Picker("Preview view", selection: $showDetail) {
                    Text("Whole picture").tag(false)
                    Text("Detail at 100%").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 260)

                HStack(spacing: 12) {
                    pane("Before", image: showDetail ? store.preview?.beforeDetail : store.preview?.before,
                         size: store.preview?.originalBytes)
                    pane("After", image: showDetail ? store.preview?.afterDetail : store.preview?.after,
                         size: store.preview?.newBytes, projected: store.preview?.isProjected ?? false, isAfter: true)
                }
                .overlay {
                    if store.isPreviewing {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Shrinking a copy in a temporary folder…").font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                        }
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                }

                if let preview = store.preview {
                    summary(preview)
                }
                ShrinkSettingsControls(store: store)
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            HStack(alignment: .center, spacing: 10) {
                Text("Applies these settings to \(store.eligible.count.formatted()) file\(store.eligible.count == 1 ? "" : "s"). Originals go to the Trash; anything less than \(Int(store.options.minimumSavingsFraction * 100))% smaller keeps its original.\(store.options.stripPhotoMetadata ? " Photos that get smaller also lose their location and camera details." : "")")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SweepButtonStyle(kind: .secondary, height: 30))
                    .fixedSize()
                Button {
                    dismiss()
                    Task { await store.run() }
                } label: {
                    Text("Shrink \(store.eligible.count.formatted()) File\(store.eligible.count == 1 ? "" : "s")")
                }
                .buttonStyle(SweepButtonStyle(kind: .warning, height: 30))
                .fixedSize()
                .disabled(store.isBusy || store.eligible.isEmpty || store.preview == nil)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Theme.surfaceSubtle)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
        .background(Theme.surface)
        .frame(minWidth: 860)
        .task(id: (store.previewTarget?.path ?? "") + store.options.encodeSignature) {
            // Debounce slider drags.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await store.loadPreview(for: store.previewTarget)
        }
    }

    private func pane(_ title: String, image: CGImage?, size: Int64?, projected: Bool = false, isAfter: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).fontWeight(.bold).foregroundStyle(Theme.ink)
                Spacer()
                if let size {
                    Text((projected ? "≈ " : "") + FileSizeHelper.formatBytes(size))
                        .fontWeight(isAfter ? .semibold : .regular)
                        .monospacedDigit()
                        .foregroundStyle(isAfter ? Theme.sweep : Theme.inkSecondary)
                }
            }
            .font(Theme.body)
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(showDetail ? .none : .high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else if !store.isPreviewing {
                    Text("No preview").font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(4)
            .frame(height: 270)
            .background(Theme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .frame(maxWidth: .infinity)
    }

    private func summary(_ preview: ShrinkPreview) -> some View {
        // Notes read "HEIC at 72% quality · first page shown": the settings go behind How, caveats stay visible.
        let noteParts = preview.note.components(separatedBy: " · ")
        let how = preview.quality.howText(note: noteParts.first ?? "")
        let caveats = noteParts.dropFirst().joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                Text("\(FileSizeHelper.formatBytes(preview.originalBytes)) → \(preview.isProjected ? "≈ " : "")\(FileSizeHelper.formatBytes(preview.newBytes))")
                    .font(Theme.display(20))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                Text("−\(Int((preview.savedFraction * 100).rounded()))%")
                    .font(Theme.display(20))
                    .monospacedDigit()
                    .foregroundStyle(Theme.sweep)
                Rectangle().fill(Theme.border).frame(width: 1, height: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quality: \(preview.quality.label)").font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                    MeterBar(fraction: preview.quality.score,
                             color: preview.quality.score > 0.6 ? Theme.sweep : Theme.warning,
                             track: Theme.hairline, height: 5)
                        .frame(width: 160)
                }
                if !caveats.isEmpty {
                    Text(caveats.prefix(1).uppercased() + caveats.dropFirst())
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
                Spacer()
                if !how.isEmpty {
                    Button(showHow ? "How ▾" : "How ▸") {
                        withAnimation(.easeOut(duration: 0.15)) { showHow.toggle() }
                    }
                    .buttonStyle(SweepLinkStyle())
                    .font(Theme.caption.weight(.medium))
                    .accessibilityLabel("How the quality was measured")
                    .accessibilityValue(showHow ? "Expanded" : "Collapsed")
                }
            }
            if showHow {
                if !how.isEmpty {
                    Text(how)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkTertiary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                        .transition(.opacity)
                }
            }
            if let problem = preview.problem {
                Label(problem, systemImage: "info.circle")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.warning)
            }
        }
    }
}

/// "Restored n originals…" row with Dismiss, used by Shrink and Format suggestions after Undo.
struct ShrinkUndoRow: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.sweep)
            Text(text)
                .font(Theme.body)
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", action: dismiss)
                .buttonStyle(SweepButtonStyle(kind: .secondary, height: 28))
                .font(Theme.caption)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .card(padding: 0)
    }
}

/// Upper-case status badge used on the Shrink boards ("LOWERS QUALITY", "INSTALLED").
struct ShrinkCapsBadge: View {
    let text: String
    let fg: Color
    let bg: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.2)
            .foregroundStyle(fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(bg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Icon and title 6pt apart, as the Shrink results header draws them.
private struct ShrinkTightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 12, weight: .semibold))
            configuration.title
        }
    }
}

/// Two columns sized first:second = ratio:1 (the board's 1.6fr / 1fr grid).
private struct ShrinkRatioColumns: Layout {
    var ratio: CGFloat
    var spacing: CGFloat

    private func widths(_ total: CGFloat) -> (CGFloat, CGFloat) {
        let usable = max(0, total - spacing)
        let first = usable * ratio / (ratio + 1)
        return (first, usable - first)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 600
        let (w1, w2) = widths(total)
        let ws = [w1, w2]
        let height = subviews.enumerated().map { i, v in
            v.sizeThatFits(ProposedViewSize(width: ws[min(i, 1)], height: nil)).height
        }.max() ?? 0
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (w1, w2) = widths(bounds.width)
        var x = bounds.minX
        for (i, v) in subviews.enumerated() {
            let w = i == 0 ? w1 : w2
            v.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: w, height: nil))
            x += w + spacing
        }
    }
}
