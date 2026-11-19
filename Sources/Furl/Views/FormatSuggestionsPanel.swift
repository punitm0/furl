import SwiftUI

/// "Format suggestions" tab inside Shrink: files that would be much smaller in another format.
/// Nothing converts until the user ticks files and confirms.
struct FormatSuggestionsPanel: View {
    @ObservedObject var store: FormatStore
    @ObservedObject var shrink: ShrinkStore
    var compressIsBusy: Bool
    @State private var confirm = false
    @State private var showSkipped = false
    @State private var showNotConverted = false

    private var otherBusy: Bool { compressIsBusy || shrink.isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: store.scanResult == nil && !store.isBusy && store.lastRun == nil ? 12 : 10) {
            Text("Finds files that would be much smaller in a newer format, measured by test-converting each one in a temporary folder. Files in projects, Git repos, synced folders and the Photos library are left alone, because a new extension can break links to them. Nothing changes until you pick files and convert.")
                .font(Theme.caption)
                .foregroundStyle(Theme.inkSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if store.isRunning {
                progressRow(title: "Converting")
            } else if let run = store.lastRun {
                results(run)
            } else if let undo = store.lastUndoSummary {
                ShrinkUndoRow(text: undo) { store.dismissResults() }
            }

            if store.isScanning {
                progressRow(title: "Looking")
            } else if let scan = store.scanResult {
                if scan.suggestions.isEmpty {
                    nothingFound(scan)
                } else {
                    summary(scan)
                    ForEach(FormatConversion.allCases) { conversion in
                        let items = scan.suggestions(conversion)
                        if !items.isEmpty { group(conversion, items) }
                    }
                }
                skipped(scan)
            } else {
                HStack(spacing: 8) {
                    Text("Looks in \(shrink.rootsLabel).").font(Theme.body).foregroundStyle(Theme.ink)
                    Spacer()
                    Button("Find Suggestions") { rescan() }
                        .buttonStyle(SweepButtonStyle(kind: .primary))
                        .fixedSize()
                        .disabled(otherBusy)
                }
            }
        }
        .confirmationDialog("Convert \(store.selectedSuggestions.count) file\(store.selectedSuggestions.count == 1 ? "" : "s")?",
                            isPresented: $confirm, titleVisibility: .visible) {
            Button("Convert") { Task { await store.convertSelected(options: shrink.options) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private func rescan() {
        Task { await store.scan(roots: shrink.roots, options: shrink.options) }
    }

    private func skippedTotal(_ scan: FormatScanResult) -> Int {
        scan.skipped.values.reduce(0, +)
    }

    /// Shown instead of a summary with zeros when the scan found nothing (ShrinkFormatStates board).
    private func nothingFound(_ scan: FormatScanResult) -> some View {
        let leftAlone = skippedTotal(scan)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.sweep)
                Text("Nothing worth converting")
                    .font(Theme.bodyStrong)
                    .foregroundStyle(Theme.ink)
            }
            Text("No file here would get at least 15% smaller in a newer format. Files that were left alone are listed below.")
                .font(Theme.caption)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button("Rescan") { rescan() }
                    .buttonStyle(SweepLinkStyle())
                    .disabled(store.isBusy || otherBusy)
                if leftAlone > 0 {
                    Button("Left alone (\(leftAlone.formatted()))") {
                        withAnimation(.easeOut(duration: 0.15)) { showSkipped.toggle() }
                    }
                    .buttonStyle(SweepLinkStyle())
                }
            }
            .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 0)
    }

    private var confirmMessage: String {
        let lossy = store.selectedLossyCount
        let lossless = store.selectedSuggestions.count - lossy
        var parts: [String] = []
        if lossy > 0 { parts.append("\(lossy) will be re-encoded at lower quality (lossy).") }
        if lossless > 0 { parts.append("\(lossless) will keep every pixel or sample (lossless).") }
        parts.append("File extensions change, so links or apps that point at the old name won't find the new file. Originals go to the Trash and Undo puts them back.")
        return parts.joined(separator: " ")
    }

    private func summary(_ scan: FormatScanResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("About")
                    Text(FileSizeHelper.formatBytes(scan.totalSavings))
                        .font(Theme.display(22))
                        .monospacedDigit()
                    Text("smaller across \(scan.suggestions.count.formatted()) suggestion\(scan.suggestions.count == 1 ? "" : "s")")
                }
                .font(Theme.body)
                .foregroundStyle(Theme.ink)
                Spacer()
                Button("Rescan") { rescan() }
                    .buttonStyle(SweepLinkStyle())
                    .font(.system(size: 12, weight: .medium))
                    .disabled(store.isBusy || otherBusy)
                Button {
                    confirm = true
                } label: {
                    Text("Convert \(store.selected.count.formatted()) File\(store.selected.count == 1 ? "" : "s")…")
                }
                .buttonStyle(SweepButtonStyle(kind: store.selectedLossyCount > 0 ? .warning : .primary, height: 36))
                .fixedSize()
                .disabled(store.selected.isEmpty || store.isBusy || otherBusy)
            }
            Text(store.selected.isEmpty ? "Tick the files you want to convert."
                 : "\(store.selected.count.formatted()) picked · about \(FileSizeHelper.formatBytes(store.selectedSavings)) smaller")
                .font(Theme.caption).foregroundStyle(Theme.inkSecondary)
        }
    }

    private func group(_ conversion: FormatConversion, _ items: [FormatSuggestion]) -> some View {
        let allOn = items.allSatisfy { store.selected.contains($0.path) }
        let savings = items.reduce(Int64(0)) { $0 + $1.estimatedSavings }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: conversion.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text(conversion.title).font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                BadgeView(text: conversion.isLossless ? "Lossless" : "Lossy",
                          color: conversion.isLossless ? Theme.sweep : Theme.warning,
                          help: conversion.isLossless ? "Every pixel or audio sample is checked to be identical."
                                                      : "Re-encoded at lower quality. The original can't be rebuilt from the result.")
                Text("about \(FileSizeHelper.formatBytes(savings)) smaller").font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                Spacer()
                Button(allOn ? "Untick All" : "Tick All") { store.setAll(conversion, selected: !allOn) }
                    .buttonStyle(SweepLinkStyle())
                    .font(.system(size: 12, weight: .medium))
            }
            if let note = conversion.compatibilityNote {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 11))
                    Text(note).lineSpacing(1)
                }
                .font(Theme.micro).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach(items.prefix(300)) { item in
                    Toggle(isOn: Binding(get: { store.selected.contains(item.path) }, set: { _ in store.toggle(item) })) {
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).font(Theme.body).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                                Text((item.folder as NSString).abbreviatingWithTildeInPath + " · " + item.note)
                                    .font(Theme.micro).foregroundStyle(Theme.inkSecondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                            Text("\(FileSizeHelper.formatBytes(item.sizeBytes)) → ~\(FileSizeHelper.formatBytes(item.estimatedBytes))")
                                .font(Theme.caption)
                                .monospacedDigit()
                                .foregroundStyle(Theme.inkSecondary)
                                .lineLimit(1)
                            Text("−\(Int((item.savingsFraction * 100).rounded()))%")
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.ink)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    .toggleStyle(.furlCheckbox)
                    .disabled(store.isBusy)
                    .padding(.vertical, 6)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    .pathContextMenu(item.path)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func skipped(_ scan: FormatScanResult) -> some View {
        let reasons = FormatSkipReason.allCases.filter { (scan.skipped[$0] ?? 0) > 0 }
        return Group {
            if !reasons.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { showSkipped.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: showSkipped ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.inkSecondary)
                                .frame(width: 11)
                            Text("Left alone (\(scan.skipped.values.reduce(0, +).formatted()))")
                                .foregroundStyle(Theme.ink)
                        }
                        .font(Theme.body)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showSkipped {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                            ForEach(reasons, id: \.self) { reason in
                                GridRow {
                                    Text(reason.label).frame(maxWidth: .infinity, alignment: .leading)
                                    Text((scan.skipped[reason] ?? 0).formatted()).monospacedDigit()
                                }
                            }
                        }
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkTertiary)
                        .padding(.leading, 17)
                        Text("Cloud-synced and recent files follow the folders you allowed in Shrink.")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.inkSecondary)
                            .padding(.leading, 17)
                    }
                }
            }
        }
    }

    private func progressRow(title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(store.phase.isEmpty ? "\(title)…" : store.phase)
                    .font(Theme.caption).foregroundStyle(Theme.inkSecondary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if store.totalCount > 0 {
                    Text("\(store.processedCount.formatted()) of \(store.totalCount.formatted())")
                        .font(Theme.caption).monospacedDigit().foregroundStyle(Theme.inkSecondary)
                }
                CancelRunButton(compact: true) { store.cancel() }
            }
            if store.totalCount > 0 {
                MeterBar(fraction: store.progressFraction, color: Theme.sweep, track: Theme.sweep.opacity(0.18), height: 4)
            }
        }
    }

    private func results(_ run: FormatRunResult) -> some View {
        let converted = run.items.filter { $0.status == .shrunk }
        let lossy = converted.filter { !$0.conversion.isLossless }.count
        let notConverted = run.items.filter { $0.status != .shrunk }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                Text(run.wasCancelled ? "Stopped" : "Converted")
                    .font(Theme.bodyStrong)
            }
            .foregroundStyle(Theme.sweep)
            HStack(spacing: 8) {
                Text("Saved \(FileSizeHelper.formatBytes(run.savedBytes))")
                    .font(.system(size: 18, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                Spacer()
                if !converted.isEmpty { Button("Undo") { Task { await store.undoLastRun() } } }
                Button("Dismiss") { store.dismissResults() }
            }
            Text("\(converted.count - lossy) lossless · \(lossy) lossy (lower quality) · \(run.count(.keptOriginal)) kept as is (less than 15% smaller) · \(run.count(.skipped)) skipped · \(run.count(.failed)) failed")
                .font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !converted.isEmpty {
                Text("Originals are in the Trash. Undo, or put them back from the Trash, until it's emptied.")
                    .font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !notConverted.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { showNotConverted.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: showNotConverted ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.inkSecondary)
                                .frame(width: 10)
                            Text("Not converted, and why (\(notConverted.count.formatted()))")
                                .font(Theme.caption)
                                .foregroundStyle(Theme.ink)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showNotConverted {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(notConverted) { item in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(item.name).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(item.message).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                                }
                                .font(Theme.caption)
                            }
                        }
                        .padding(.leading, 16)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 0)
    }
}
