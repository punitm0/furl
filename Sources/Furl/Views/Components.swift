import AppKit
import SwiftUI

/// Small label badge. Boards draw it as 10.5pt semibold on the colour's tint token
/// (mintTint, warningTint, memoryTint…), padding 2 × 7, radius 6.
struct BadgeView: View {
    let text: String
    let color: Color
    var help: String? = nil
    /// Overrides the tint; by default the matching Theme tint token is used.
    var background: Color? = nil

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(background ?? Self.tint(for: color), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .foregroundStyle(color)
            .help(help ?? text)
    }

    /// Theme tint token for a Theme foreground colour; 14% of the colour when the board names none.
    static func tint(for color: Color) -> Color {
        let pairs: [(Color, Color)] = [
            (Theme.sweep, Theme.mintTint),
            (Theme.warning, Theme.warningTint),
            (Theme.danger, Theme.dangerTint),
            (Theme.memory, Theme.memoryTint),
            (Theme.violet, Theme.violetTint),
            (Theme.accentTeal.fg, Theme.accentTeal.bg),
            (Theme.accentPink.fg, Theme.accentPink.bg),
            (Theme.inkSecondary, Theme.accentGray.bg)
        ]
        return pairs.first(where: { $0.0 == color })?.1 ?? color.opacity(0.14)
    }
}

/// White (or dark-mode surface) card with a hairline border, used across the app.
struct CardBackground: ViewModifier {
    var padding: CGFloat = 16
    var radius: CGFloat = Theme.Radius.card

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
    }
}

extension View {
    func card(padding: CGFloat = 16, radius: CGFloat = Theme.Radius.card) -> some View {
        modifier(CardBackground(padding: padding, radius: radius))
    }

    /// Puts a List inside a Clean Slate card on the page ground.
    func cardList() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .padding(.horizontal, Theme.Space.page)
            .padding(.vertical, 14)
    }

    /// Clean Slate page ground + Sweep tint for controls. Apply to each screen's root.
    func cleanSlateScreen() -> some View {
        self
            .background(Theme.ground)
            .tint(Theme.sweep)
    }

    /// Standard Reveal / Open / Copy Path context menu for any row representing a file system path.
    /// `dontScan` adds "Don't scan here…" (SettingsMoved board), which asks before skipping the folder.
    func pathContextMenu(_ path: String, allowOpen: Bool = true, dontScan: (() -> Void)? = nil) -> some View {
        contextMenu {
            Button {
                InspectorStore.shared.show(path: path, state: AppServices.state)
            } label: {
                Label("Show in Inspector", systemImage: "sidebar.right")
            }
            Divider()
            Button {
                DeletionService.revealInFinder(path)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            if allowOpen {
                Button {
                    DeletionService.open(path)
                } label: {
                    Label("Open", systemImage: "arrow.up.forward.app")
                }
            }
            Divider()
            Button {
                DeletionService.copyPath(path)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
            if let dontScan {
                Divider()
                Button(action: dontScan) {
                    Label("Don’t scan here…", systemImage: "eye.slash")
                }
            }
        }
    }
}

/// Overview category tile: icon chip, big display number, one-line detail.
struct SummaryCard: View {
    let title: String
    let value: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    var tintBackground: Color? = nil
    var unit: String? = nil
    var tag: String? = nil
    var isLoading: Bool = false
    /// A check mark in place of the chevron: this area just finished (FirstScan board).
    var isDone: Bool = false
    var action: (() -> Void)? = nil

    @State private var isHovering = false

    var body: some View {
        Button {
            action?()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 28, height: 28)
                        .background(tintBackground ?? tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(title)
                        .font(Theme.bodyStrong)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let tag {
                        Text(tag)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tintBackground ?? tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else if isDone {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.sweep)
                            .accessibilityLabel("Done")
                    } else if action != nil {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.inkSecondary.opacity(isHovering ? 1 : 0.5))
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value)
                        .font(Theme.display(26))
                        .tracking(-0.5)
                        .foregroundStyle(Theme.ink)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.4), value: value)
                    if let unit {
                        Text(unit)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
                Text(subtitle)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .card(padding: 16)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(tint.opacity(isHovering ? 0.55 : 0), lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(isHovering ? 0.06 : 0), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}

/// Horizontal bar made of proportional colored segments.
struct SegmentedUsageBar: View {
    struct Segment: Identifiable {
        let id: String
        let fraction: Double
        let color: Color
    }

    let segments: [Segment]
    var height: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(segments) { seg in
                    Rectangle()
                        .fill(seg.color)
                        .frame(width: max(0, geo.size.width * min(1, max(0, seg.fraction))))
                }
                Spacer(minLength: 0)
            }
            .background(Theme.border)
            .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
        }
        .frame(height: height)
    }
}

struct LegendDot: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(Theme.inkTertiary)
            Text(value).monospacedDigit().foregroundStyle(Theme.ink)
        }
        .font(Theme.caption)
    }
}

struct AppIconView: View {
    let bundlePath: String
    let size: CGFloat

    var body: some View {
        let nsImage = NSWorkspace.shared.icon(forFile: bundlePath)
        Image(nsImage: nsImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

struct EmptyStatePlaceholder: View {
    let systemImage: String
    let title: String
    let message: String
    var buttonTitle: String? = nil
    /// Primary by default; WorktreesSimple's "Open Scanning Settings" is secondary.
    var buttonKind: SweepButtonStyle.Kind = .primary
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Theme.sweep)
                .frame(width: 64, height: 64)
                .background(Theme.mintTint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(Theme.body)
                .lineSpacing(4)
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .buttonStyle(SweepButtonStyle(kind: buttonKind))
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ScanningPlaceholder: View {
    let message: String
    /// The scan's live status: before the first result arrives the placeholder says what's being
    /// looked at and shows the same progress bar as the live strip (canvas "Results still arriving").
    var status: LiveScanStatus? = nil

    var body: some View {
        VStack(spacing: 10) {
            ScanningMark()
                .frame(width: 56, height: 56)
            Text(message)
                .font(Theme.body.weight(.medium))
                .foregroundStyle(Theme.ink)
            if let status {
                Text(status.detail.isEmpty ? "Nothing found yet" : "Nothing found yet · \(status.detail)")
                    .font(Theme.caption.monospacedDigit())
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 420)
                ScanStripBar(fraction: status.fraction)
                    .frame(width: 220)
                    .clipShape(Capsule())
                    .padding(.top, 2)
            } else {
                Text("This can take a minute on large folders.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The scanning spinner (Junk/Apps/Duplicates scanning states): a mintTint track (r 22, stroke 7 in a 64 box) with a 34%
/// sweep arc, one turn every 1.6 s. Still under Reduce Motion.
struct ScanningMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let turns = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                let line = side * 7 / 64
                let inset = side * 10 / 64
                ZStack {
                    Circle().inset(by: inset).stroke(Theme.mintTint, lineWidth: line)
                    Circle().inset(by: inset)
                        .trim(from: 0, to: 0.34)
                        .stroke(Theme.sweep, style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(-60 + turns * 360))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Scanning")
    }
}

/// Bottom bar summarising the current selection with the primary action.
/// The action keeps the `.destructive` role and ⌘⌫, but is drawn in Sweep green: in the
/// default mode items go to the Trash and can be undone.
/// "N selected items aren't shown": ticked items the current filter hides still get cleaned,
/// so the bottom bar and the confirm say so.
func hiddenSelectionNote(_ count: Int) -> String? {
    guard count > 0 else { return nil }
    return "\(count) selected item\(count == 1 ? " isn't" : "s aren't") shown"
}

struct SelectionActionBar: View {
    let selectedCount: Int
    let totalCount: Int
    let selectedBytes: Int64
    let actionTitle: String
    /// Fill of the main action: `.danger` in permanent-delete mode (AuditDecisions), `.primary` otherwise.
    var actionKind: SweepButtonStyle.Kind = .primary
    let isBusy: Bool
    var note: String? = nil
    /// Shows an "Add to Tray" button that adds the selection to the cleanup tray.
    var onAddToTray: (() -> Void)? = nil
    /// "⌘⌫" hint after the action (Worktrees, Duplicates, Large Files boards; not on the Junk board).
    var showsShortcutHint: Bool = true
    let onSelectAll: () -> Void
    let onSelectNone: () -> Void
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Text("\(selectedCount) of \(totalCount)")
                    .font(Theme.bodyStrong)
                    .foregroundStyle(Theme.ink)
                Text("selected")
                    .foregroundStyle(Theme.inkTertiary)
                if selectedBytes > 0 {
                    Text("· \(FileSizeHelper.formatBytes(selectedBytes))")
                        .foregroundStyle(Theme.inkTertiary)
                }
                if let note {
                    Text("· \(note)")
                        .foregroundStyle(Theme.inkTertiary)
                        .lineLimit(1)
                }
            }
            .font(Theme.body)
            .monospacedDigit()

            Button("Select All", action: onSelectAll)
                .buttonStyle(SweepLinkStyle())
                .disabled(totalCount == 0)
            Button("Select None", action: onSelectNone)
                .buttonStyle(SweepLinkStyle())
                .disabled(selectedCount == 0)
            Spacer()
            if isBusy {
                ProgressView().controlSize(.small)
            }
            if let onAddToTray {
                AddToTrayButton(count: selectedCount, action: onAddToTray)
            }
            Button(role: .destructive, action: onAction) {
                Text("\(actionTitle) \(FileSizeHelper.formatBytes(selectedBytes))")
                    .monospacedDigit()
            }
            .buttonStyle(SweepButtonStyle(kind: actionKind))
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(selectedCount == 0 || isBusy)
            if showsShortcutHint {
                Text("⌘⌫")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .tint(Theme.sweep)
        .padding(.horizontal, Theme.Space.page)
        .frame(minHeight: 60)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

/// Checkbox toggle bound to membership of `id` in a selection set.
struct SelectionCheckbox: View {
    let id: String
    @Binding var selection: Set<String>
    var disabled: Bool = false

    var body: some View {
        Toggle("", isOn: Binding(
            get: { selection.contains(id) },
            set: { checked in
                if checked { selection.insert(id) } else { selection.remove(id) }
            }
        ))
        .labelsHidden()
        .toggleStyle(.furlCheckbox)
        .tint(Theme.sweep)
        .disabled(disabled)
    }
}

extension Date {
    var relativeDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}

// MARK: - Clean Slate building blocks

/// Page header: title, one-line subtitle, trailing accessories. 64pt tall with a bottom hairline.
struct ScreenHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        ScreenHeaderLayout {
            // One line, always: a narrow page (cleanup tray open) used to wrap "Caches & Junk"
            // one word per line. The controls move under the title first; past that it truncates.
            Text(title)
                .font(Theme.pageTitle)
                .tracking(-0.3)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutValue(key: ScreenHeaderRole.self, value: .title)
            if let subtitle {
                Text(subtitle)
                    .font(Theme.pageSubtitle)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(subtitle)
                    .layoutValue(key: ScreenHeaderRole.self, value: .subtitle)
            }
            HStack(spacing: 12) {
                trailing()
            }
            .layoutValue(key: ScreenHeaderRole.self, value: .trailing)
        }
        .controlSize(.regular)
        .padding(.horizontal, Theme.Space.page)
        .padding(.vertical, 10)
        .frame(minHeight: 64)
        .background(Theme.ground)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        // The cleanup tray carries this strip and its hairline on over its column.
        .anchorPreference(key: ScreenHeaderBoundsKey.self, value: .bounds) { $0 }
    }
}

private enum ScreenHeaderRole: LayoutValueKey {
    enum Role { case title, subtitle, trailing }
    static let defaultValue: Role = .title
}

/// Title (with its subtitle under it) and controls on one row while the whole title and the
/// controls at their narrowest fit; on a narrower page (cleanup tray open) the controls drop to a
/// second row, leading-aligned, and only then does the title truncate.
private struct ScreenHeaderLayout: Layout {
    var gap: CGFloat = 12
    var rowSpacing: CGFloat = 8
    static let subtitleSpacing: CGFloat = 2

    private struct Plan {
        var stacked = false
        var title: CGSize = .zero
        var subtitle: CGSize = .zero
        var trailing: CGSize = .zero
        var hasSubtitle = false
        var leftHeight: CGFloat { title.height + (hasSubtitle ? ScreenHeaderLayout.subtitleSpacing + subtitle.height : 0) }
        var leftWidth: CGFloat { max(title.width, subtitle.width) }
    }

    private func find(_ role: ScreenHeaderRole.Role, _ subviews: Subviews) -> LayoutSubview? {
        subviews.first { $0[ScreenHeaderRole.self] == role }
    }

    private func plan(_ width: CGFloat?, _ subviews: Subviews) -> Plan {
        var p = Plan()
        guard let title = find(.title, subviews) else { return p }
        let subtitle = find(.subtitle, subviews)
        let trailing = find(.trailing, subviews)
        p.hasSubtitle = subtitle != nil
        let titleIdeal = title.sizeThatFits(.unspecified)
        let trailingIdeal = trailing?.sizeThatFits(.unspecified) ?? .zero
        let trailingMin = trailing?.sizeThatFits(ProposedViewSize(width: 0, height: nil)) ?? .zero

        let leftWidth: CGFloat
        guard let width else {
            p.title = titleIdeal
            p.subtitle = subtitle?.sizeThatFits(.unspecified) ?? .zero
            p.trailing = trailingIdeal
            return p
        }
        if trailingIdeal.width == 0 {
            leftWidth = width
        } else if titleIdeal.width + gap + trailingMin.width <= width {
            let trailingWidth = min(trailingIdeal.width, max(trailingMin.width, width - titleIdeal.width - gap))
            p.trailing = trailing?.sizeThatFits(ProposedViewSize(width: trailingWidth, height: nil)) ?? .zero
            leftWidth = max(0, width - p.trailing.width - gap)
        } else {
            p.stacked = true
            p.trailing = trailing?.sizeThatFits(ProposedViewSize(width: width, height: nil)) ?? .zero
            leftWidth = width
        }
        let titleSize = title.sizeThatFits(ProposedViewSize(width: min(titleIdeal.width, leftWidth), height: nil))
        p.title = CGSize(width: min(titleSize.width, leftWidth), height: titleSize.height)
        if let subtitle {
            let size = subtitle.sizeThatFits(ProposedViewSize(width: leftWidth, height: nil))
            p.subtitle = CGSize(width: min(size.width, leftWidth), height: size.height)
        }
        return p
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let p = plan(proposal.width, subviews)
        if p.stacked {
            return CGSize(width: proposal.width ?? max(p.leftWidth, p.trailing.width),
                          height: p.leftHeight + rowSpacing + p.trailing.height)
        }
        let natural = p.leftWidth + (p.trailing.width > 0 ? gap + p.trailing.width : 0)
        return CGSize(width: proposal.width ?? natural, height: max(p.leftHeight, p.trailing.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let p = plan(bounds.width, subviews)
        let total = p.stacked ? p.leftHeight + rowSpacing + p.trailing.height : p.leftHeight
        let top = p.stacked ? bounds.midY - total / 2 : bounds.midY - p.leftHeight / 2
        find(.title, subviews)?.place(at: CGPoint(x: bounds.minX, y: top), anchor: .topLeading,
                                      proposal: ProposedViewSize(p.title))
        find(.subtitle, subviews)?.place(at: CGPoint(x: bounds.minX, y: top + p.title.height + Self.subtitleSpacing),
                                         anchor: .topLeading, proposal: ProposedViewSize(p.subtitle))
        guard let trailing = find(.trailing, subviews) else { return }
        if p.stacked {
            trailing.place(at: CGPoint(x: bounds.minX, y: top + p.leftHeight + rowSpacing), anchor: .topLeading,
                           proposal: ProposedViewSize(width: bounds.width, height: nil))
        } else {
            trailing.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                           proposal: ProposedViewSize(width: p.trailing.width, height: nil))
        }
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Uppercase section label (sidebar groups, card headings).
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(Theme.sectionLabel)
            .tracking(0.4)
            .foregroundStyle(Theme.inkSecondary)
    }
}

/// Count pill: tinted capsule with bold number (sidebar badges).
struct CountPill: View {
    let text: String
    var fg: Color = Theme.sweep
    var bg: Color = Theme.mintTint

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(bg, in: Capsule())
    }
}

/// Primary / secondary / quiet button styles.
struct SweepButtonStyle: ButtonStyle {
    enum Kind {
        /// Sweep green fill, white text.
        case primary
        /// Surface fill with control border.
        case secondary
        /// Mint fill on pine (hero).
        case heroPrimary
        /// Transparent with pine border (hero).
        case heroSecondary
        /// Red-tinted, for permanent-delete mode or truly destructive actions.
        case danger
        /// Orange fill for lossy, can't-fully-undo actions (Shrink).
        case warning
    }

    var kind: Kind = .primary
    var height: CGFloat = 32
    var fullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, height: height, fullWidth: fullWidth)
    }

    private struct StyledButton: View {
        let configuration: ButtonStyle.Configuration
        let kind: Kind
        let height: CGFloat
        let fullWidth: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: kind == .heroPrimary ? 15 : (isSmall ? 12 : (isLarge ? 14 : 13)), weight: kind == .heroPrimary ? .bold : .semibold))
                .lineLimit(1)
                .padding(.horizontal, (kind == .primary || kind == .danger) && !isSmall ? 16 : 12)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .frame(height: height)
                .foregroundStyle(foreground)
                .background(background, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(border, lineWidth: 1)
                )
                .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : (kind == .heroPrimary ? 1 : 0.45))
                .brightness(hovering && isEnabled && !configuration.isPressed ? 0.03 : 0)
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .onHover { hovering = $0 }
        }

        /// 28pt buttons on the boards (States, Settings › Permissions) use 12pt text and 12pt padding.
        private var isSmall: Bool { height <= 28 && kind != .heroPrimary && kind != .heroSecondary }
        /// Buttons 38pt or taller use a 14pt label (AuditDecisions). Hero buttons keep their own sizes.
        private var isLarge: Bool { height >= 38 && kind != .heroPrimary && kind != .heroSecondary }

        private var radius: CGFloat {
            switch kind {
            case .heroPrimary, .heroSecondary: return 12
            default: return isSmall ? Theme.Radius.control : Theme.Radius.button
            }
        }

        private var foreground: Color {
            switch kind {
            case .primary: return Theme.onSweep
            case .danger: return Theme.onDanger
            case .warning: return Theme.onWarning
            case .secondary: return Theme.ink
            case .heroPrimary: return isEnabled ? Theme.onMint : Theme.pineMuted
            case .heroSecondary: return Theme.onPine
            }
        }

        private var background: Color {
            switch kind {
            case .primary: return Theme.sweep
            case .danger: return Theme.danger
            case .warning: return Theme.warning
            case .secondary: return Theme.surface
            // Disabled hero button: pineTrack + pineMuted label (≥4.9:1), never faded mint.
            case .heroPrimary: return isEnabled ? Theme.mint : Theme.pineTrack
            case .heroSecondary: return .clear
            }
        }

        private var border: Color {
            switch kind {
            case .secondary: return Theme.controlBorder
            case .heroSecondary: return Theme.pineBorder
            default: return .clear
            }
        }
    }
}

/// Thin horizontal meter (row size bars, disk meter).
struct MeterBar: View {
    let fraction: Double
    var color: Color = Theme.sweep
    var track: Color = Theme.hairline
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(color)
                    .frame(width: max(fraction > 0 ? height : 0, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }
}

/// Small pill-shaped filter chip.
struct FilterChip: View {
    let title: String
    var systemImage: String? = nil
    var detail: String? = nil
    var swatch: Color? = nil
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let swatch {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(swatch).frame(width: 8, height: 8)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                if let detail {
                    Text(detail)
                        .foregroundStyle(isActive ? Theme.sweepDeep.opacity(0.8) : Theme.inkSecondary)
                        .monospacedDigit()
                }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .foregroundStyle(isActive ? Theme.sweepDeep : Theme.ink)
            .background(isActive ? Theme.mintTint : Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(isActive ? Theme.sweep.opacity(0.35) : Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Search field matching the header controls.
struct HeaderSearchField: View {
    @Binding var text: String
    var prompt: String = "Search"
    var width: CGFloat = 220

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSecondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.body)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.inkSecondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 120, idealWidth: width, maxWidth: width)
        .frame(height: 30)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }
}

/// Grouped list section card: header row on a subtle ground, rows separated by hairlines.
struct GroupCard<Header: View, Content: View>: View {
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            header()
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surfaceSubtle)
            content()
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }
}

/// A row inside a `GroupCard`, with a top hairline.
struct GroupRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// Text-only link button in Sweep green (system `.link` style ignores tint and draws blue).
struct SweepLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LinkLabel(configuration: configuration)
    }

    private struct LinkLabel: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? Theme.sweep : Theme.inkSecondary.opacity(0.6))
                .underline(hovering && isEnabled)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// Styled Cancel / Stop for running scans and jobs (replaces bare system buttons).
/// Compact matches the Duplicates board "Stop scan": 24pt, 12pt semibold, radius 8, padding 12.
struct CancelRunButton: View {
    var title = "Cancel"
    var compact = false
    let action: () -> Void

    var body: some View {
        if compact {
            Button(action: action) {
                Label(title, systemImage: "xmark")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(CompactCancelStyle())
            .fixedSize()
            .keyboardShortcut(.cancelAction)
        } else {
            Button(action: action) {
                Label(title, systemImage: "xmark")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 8)
            }
            .buttonStyle(SweepButtonStyle(kind: .secondary, height: 34))
            .fixedSize()
            .keyboardShortcut(.cancelAction)
        }
    }

    private struct CompactCancelStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.controlBorder, lineWidth: 1))
                .opacity(configuration.isPressed ? 0.82 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// App-styled dropdown ("Sort by  Total size ⌄") used in toolbars instead of the stock
/// pop-up button, so it matches the rest of the app in light and dark.
struct SweepMenuPicker<Value: Hashable>: View {
    var label: String? = nil
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var systemImage: String? = nil
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let label {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
            }
            Menu {
                ForEach(options, id: \.self) { option in
                    Button {
                        selection = option
                    } label: {
                        if option == selection {
                            Label(title(option), systemImage: "checkmark")
                        } else {
                            Text(title(option))
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    Text(title(selection))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .monospacedDigit()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.inkSecondary)
                        .rotationEffect(.degrees(hovering ? 0 : 0))
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(hovering ? Theme.surfaceSubtle : Theme.surface,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(hovering ? Theme.sweep.opacity(0.5) : Theme.controlBorder, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        }
        .fixedSize()
    }
}

/// 28pt toolbar button from the as-built boards (Rescan): surface fill, control border,
/// 8pt radius, 12pt semibold label.
struct ToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ToolbarButtonLabel(configuration: configuration)
    }

    private struct ToolbarButtonLabel: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(Theme.controlBorder, lineWidth: 1)
                )
                .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
    }
}

/// 22pt chip from the as-built boards (Space Map target menu, Duplicates Auto-Select):
/// surface fill, 1px control border, 5pt radius, 12pt label with icon and optional chevron.
/// Used as a custom `Menu` label so the menu doesn't draw as a grey system pill.
///
struct ToolbarChipLabel: View {
    let title: String
    var systemImage: String? = nil
    var showsChevron = false
    var weight: Font.Weight = .regular
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.ink)
            }
            Text(title)
                .font(.system(size: 12, weight: weight))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.controlBorder, lineWidth: 1))
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(Rectangle())
    }
}

// MARK: - Controls (FurlTokens board, "Controls: checkbox and pop-up")

/// Furl's checkbox, drawn instead of the stock grey one. 14×14, radius 4. Off: 1pt
/// `controlBorder` on `surface`. On (or mixed): `sweep` fill with an `onSweep` check (or dash).
/// Disabled: the whole control at 45%. Label sits 8pt after the box and keeps the caller's font.
struct FurlCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        FurlCheckboxBody(configuration: configuration)
    }
}

extension ToggleStyle where Self == FurlCheckboxStyle {
    /// `.toggleStyle(.furlCheckbox)`: the design's checkbox in every palette, light and dark.
    static var furlCheckbox: FurlCheckboxStyle { FurlCheckboxStyle() }
}

private struct FurlCheckboxBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    private var filled: Bool { configuration.isOn || configuration.isMixed }

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                box
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(FurlCheckboxPressStyle())
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityRepresentation {
            // VoiceOver sees a real checkbox: role, label and checked/unchecked value.
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.checkbox)
        }
    }

    private var box: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(filled ? Theme.sweep : Theme.surface)
            if !filled {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.controlBorder, lineWidth: 1)
            }
            if configuration.isMixed {
                Capsule().fill(Theme.onSweep).frame(width: 7, height: 1.8)
            } else if configuration.isOn {
                FurlCheckmark()
                    .stroke(Theme.onSweep, style: StrokeStyle(lineWidth: 1.45, lineCap: .round, lineJoin: .round))
                    .frame(width: 10, height: 10)
            }
        }
        .frame(width: 14, height: 14)
        .fixedSize()
    }
}

/// Slight dim while the mouse is down, like the system control.
private struct FurlCheckboxPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// The design's check: `M5 12l5 5 9-10` in a 24-unit box.
private struct FurlCheckmark: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + 5 * s, y: rect.minY + 12 * s))
        p.addLine(to: CGPoint(x: rect.minX + 10 * s, y: rect.minY + 17 * s))
        p.addLine(to: CGPoint(x: rect.minX + 19 * s, y: rect.minY + 7 * s))
        return p
    }
}

/// Furl's inline pop-up menu, drawn instead of the stock pop-up button. 20pt high, radius 5,
/// `surface` fill with a 1pt `controlBorder`, 12pt value, and the ↕ chevron on a 14×14 radius-3
/// `sweep` square (glyph `onSweep`). Disabled: the whole control at 45%.
/// The options are ordinary Picker content (`Text(…).tag(…)`, `Section`s), shown in the system
/// menu with a check on the current value; `value` is the text shown in the closed control.
struct FurlPopUp<Selection: Hashable, Options: View>: View {
    let label: String
    @Binding var selection: Selection
    let value: String
    @ViewBuilder var options: () -> Options

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    init(_ label: String, selection: Binding<Selection>, value: String,
         @ViewBuilder options: @escaping () -> Options) {
        self.label = label
        self._selection = selection
        self.value = value
        self.options = options
    }

    var body: some View {
        Menu {
            Picker(label, selection: $selection) { options() }
                .pickerStyle(.inline)
                .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(value)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                Text("↕")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.onSweep)
                    .frame(width: 14, height: 14)
                    .background(Theme.sweep, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .frame(height: 20)
            .background(hovering && isEnabled ? Theme.surfaceSubtle : Theme.surface,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Theme.controlBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.1), radius: 0.5, y: 0.5)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}
