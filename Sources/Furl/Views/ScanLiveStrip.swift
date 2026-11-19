import SwiftUI

/// Canvas "Results still arriving": the strip under a screen header while a scan keeps going.
/// mintTint, 28 × 9 padding, 13 pt; a 4 pt sweep bar on a sweep 18% track along the bottom edge,
/// filled to the real fraction when the total is known, else a 24% segment sweeping across (1.6 s).
/// Finished: check, "Scan finished", count and size. Stopped: surfaceSubtle, pause, "Scan again".
struct ScanLiveStrip: View {
    let status: LiveScanStatus
    var onStop: (() -> Void)?
    var onRescan: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            icon
            switch status.phase {
            case .running:
                Text("Still scanning").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                countText(suffix: " so far")
                secondary
                Spacer(minLength: 6)
                if let fraction = status.fraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.sweep)
                }
                if let onStop {
                    Button("Stop", action: onStop)
                        .buttonStyle(SweepButtonStyle(kind: .secondary, height: 24))
                        .fixedSize()
                        .help("Stop scanning. What's been found stays on screen.")
                }
            case .finished:
                Text("Scan finished").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                countText(suffix: "")
                Spacer(minLength: 6)
            case .stopped:
                Text("Stopped").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("Showing the \(status.countText) found before you stopped. Totals may be low.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if let onRescan {
                    Button("Scan again", action: onRescan)
                        .buttonStyle(SweepLinkStyle())
                        .font(.system(size: 13, weight: .medium))
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(status.phase == .stopped ? Theme.surfaceSubtle : Theme.mintTint)
        .overlay(alignment: .bottom) {
            if status.phase == .running { ScanStripBar(fraction: status.fraction) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1).opacity(status.phase == .running ? 0 : 1) }
        .accessibilityElement(children: .contain)
        .animation(.easeOut(duration: 0.2), value: status.phase)
    }

    @ViewBuilder private var icon: some View {
        switch status.phase {
        case .running:
            ScanningMark().frame(width: 16, height: 16)
        case .finished:
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.sweep)
        case .stopped:
            Image(systemName: "pause").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
        }
    }

    private func countText(suffix: String) -> some View {
        (Text("\(status.countText)\(suffix) · ").foregroundStyle(Theme.ink)
            + Text(FileSizeHelper.formatBytes(status.foundBytes))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.sweep))
            .font(.system(size: 13).monospacedDigit())
            .contentTransition(.numericText())
            .lineLimit(1)
            .fixedSize()
    }

    /// The folder being read (monospaced, middle-truncated), else what the scan is doing now.
    @ViewBuilder private var secondary: some View {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !status.current.isEmpty {
            Text(status.current.replacingOccurrences(of: home, with: "~"))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else if !status.detail.isEmpty {
            Text(status.detail)
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// 4 pt bar on a sweep 18% track: determinate when `fraction` is known, else a sweeping 24% segment.
struct ScanStripBar: View {
    let fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.sweep.opacity(0.18))
                if let fraction {
                    Rectangle().fill(Theme.sweep)
                        .frame(width: geo.size.width * fraction)
                        .animation(.easeOut(duration: 0.3), value: fraction)
                } else {
                    TimelineView(.animation(paused: reduceMotion)) { context in
                        let t = reduceMotion ? 0.38 : context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 1.6) / 1.6
                        let segment = geo.size.width * 0.24
                        Rectangle().fill(Theme.sweep)
                            .frame(width: segment)
                            .offset(x: (geo.size.width + segment) * t - segment)
                    }
                }
            }
            .clipped()
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("Scan progress")
        .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "In progress")
    }
}

/// Puts the live strip under a screen's header when there is something to say: results on screen
/// while the scan runs, or the finished / stopped line.
struct LiveScanStripSlot: View {
    let status: LiveScanStatus?
    var onStop: (() -> Void)?
    var onRescan: (() -> Void)?

    var body: some View {
        if let status, status.phase != .running || status.foundCount > 0 {
            ScanLiveStrip(status: status, onStop: onStop, onRescan: onRescan)
                .transition(.opacity)
        }
    }
}
