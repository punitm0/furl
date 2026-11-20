import SwiftUI

extension RiskTier {
    /// Safe stays green in every theme; Check first is orange; Permanent uses the danger tokens.
    var foreground: Color {
        switch self {
        case .safe: return Theme.safe
        case .checkFirst: return Theme.warning
        case .permanent: return Theme.danger
        }
    }

    var tint: Color {
        switch self {
        case .safe: return Theme.safeTint
        case .checkFirst: return Theme.warningTint
        case .permanent: return Theme.dangerTint
        }
    }
}

/// WhySafe board: one-word risk chip. 11 pt semibold, padding 2×7, radius 6 (10 pt, 1×6 in the legend).
struct RiskChip: View {
    let tier: RiskTier
    var compact = false
    /// Extra hover text, e.g. why this item is Permanent.
    var help: String? = nil

    var body: some View {
        Text(tier.label)
            .font(.system(size: compact ? 10 : 11, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, compact ? 6 : 7)
            .padding(.vertical, compact ? 1 : 2)
            .foregroundStyle(tier.foreground)
            .background(tier.tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .help(help ?? "\(tier.label): \(tier.meaning)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tier.accessibilityLabel)
    }
}

/// WhySafe board: the legend line at the top of a list. Padding 8×12, radius 9, subtle surface,
/// hairline border, 11.5 pt secondary text, 18 pt between entries.
struct RiskLegend: View {
    var tiers: [RiskTier] = [.safe, .checkFirst]

    var body: some View {
        HStack(spacing: 18) {
            ForEach(tiers, id: \.self) { tier in
                HStack(spacing: 6) {
                    RiskChip(tier: tier, compact: true)
                    Text(tier.meaning)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tier.accessibilityLabel)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.inkSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What the labels mean")
    }
}

/// An optional link in the popover's footer (e.g. "Always skip npm cache", "Open in Finder").
struct WhyAction {
    let title: String
    let perform: () -> Void
}

/// WhySafe board: the "Why?" button on a row and the evidence popover it opens. 22 pt tall, padding 7,
/// radius 6, 11.5 pt medium; tinted with the accent while open.
struct WhyButton: View {
    let explanation: WhyExplanation
    var action: WhyAction? = nil
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11, weight: .medium))
                Text("Why?")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .foregroundStyle(isOpen ? Theme.sweepDeep : Theme.inkSecondary)
            .background(isOpen ? Theme.mintTint : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(explanation.title)
        .accessibilityLabel("Why? \(explanation.title)")
        .accessibilityHint("Shows the evidence")
        .popover(isPresented: $isOpen, arrowEdge: .trailing) {
            WhyPopover(explanation: explanation, action: action) { isOpen = false }
        }
    }
}

/// The evidence popover (same pattern as Processes): 360 wide, padding 14, gap 10; 13 pt semibold
/// title with the chip, 12 pt lines with a 13 pt icon, then an optional footer.
struct WhyPopover: View {
    let explanation: WhyExplanation
    var action: WhyAction? = nil
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(explanation.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                if let tier = explanation.tier {
                    RiskChip(tier: tier)
                }
            }
            ForEach(explanation.lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    icon(for: line.mark)
                    (Text(line.label).fontWeight(.semibold).foregroundColor(Theme.ink)
                        + Text(" " + line.text))
                        .font(.system(size: 12))
                        .lineSpacing(2)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            Divider().overlay(Theme.hairline)
            HStack(spacing: 8) {
                if let action {
                    Button(action.title) {
                        action.perform()
                        close()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.sweepDeep)
                    .fixedSize()
                }
                Spacer()
                Button("Got it", action: close)
                    .buttonStyle(SweepButtonStyle(kind: .secondary, height: 26))
                    .keyboardShortcut(.defaultAction)
                    .fixedSize()
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
    }

    @ViewBuilder private func icon(for mark: WhyExplanation.Mark) -> some View {
        let (name, color): (String, Color) = {
            switch mark {
            case .info: return ("info.circle", Theme.inkSecondary)
            case .good: return ("checkmark.circle", Theme.safe)
            case .bad: return ("xmark", Theme.inkSecondary)
            case .time: return ("clock", Theme.inkSecondary)
            }
        }()
        Image(systemName: name)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 13)
            .accessibilityHidden(true)
    }
}
