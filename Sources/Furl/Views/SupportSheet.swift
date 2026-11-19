import AppKit
import SwiftUI

/// "Pay what you like" sheet. Shown after a big cleanup (via `SupportStore.pendingPrompt`) or on demand
/// from the sidebar / About window. Every feature stays unlocked whatever the user picks.
/// Motion follows the PayWhatYouLike board's motion spec table, including its Reduce Motion column.
struct SupportSheet: View {
    /// What the cleanup that triggered the sheet freed; nil when the user opened it themselves.
    let freedBytes: Int64?
    /// Total freed since the user started using Furl (AppState.lifetimeFreedBytes).
    let lifetimeBytes: Int64
    @ObservedObject var store: SupportStore = .shared

    private enum Stage { case picker, checkoutOpened, paid }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var amount: Int
    @State private var otherText = ""
    @State private var usingOther = false
    @State private var stage: Stage = .picker
    @FocusState private var otherFocused: Bool
    @FocusState private var focusedChip: Int?

    // Count-up (only when the sheet opens because of a cleanup).
    @State private var shownFreed: Double = 0
    @State private var lifetimeOpacity: Double
    @State private var washTrigger = 0
    @State private var otherRingTrigger = 0
    @State private var otherPressed = false

    // Thank-you furl.
    @State private var paidAt: Date?
    @State private var furlFinished = false
    @State private var reducedMarkOpacity: Double = 0

    init(freedBytes: Int64?, lifetimeBytes: Int64, store: SupportStore = .shared) {
        self.freedBytes = freedBytes
        self.lifetimeBytes = lifetimeBytes
        self.store = store
        _amount = State(initialValue: freedBytes.map(SupportConfig.suggestedAmount(forFreedBytes:)) ?? SupportConfig.defaultAmount)
        // Opened from the sidebar or About nothing counts, so the lifetime line is there from the start.
        _lifetimeOpacity = State(initialValue: freedBytes == nil ? 1 : 0)
    }

    private enum OtherState { case empty, valid(Int), outOfRange }

    private var otherState: OtherState {
        let digits = otherText.trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty else { return .empty }
        guard let value = Int(digits), value >= 1, value <= SupportConfig.maximumAmount else { return .outOfRange }
        return .valid(value)
    }

    private var otherOutOfRange: Bool {
        if usingOther, case .outOfRange = otherState { return true }
        return false
    }

    private var chosenAmount: Int? {
        guard usingOther else { return amount }
        if case .valid(let value) = otherState { return value }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            switch stage {
            case .picker:
                header
                picker
            case .checkoutOpened:
                header
                checkoutOpened
            case .paid:
                furlHeader
                paidThanks
            }
        }
        .frame(width: 520)
        .background(Theme.surface)
        .onAppear(perform: startCountUp)
        .onAppear { store.refreshCheckoutLink() }
    }

    // MARK: Header

    private var header: some View {
        // MenuSupportStates board: the freed group (gap 6) and the lifetime line sit 8 apart.
        VStack(alignment: .leading, spacing: 8) {
            if freedBytes != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Done. You just freed")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.pineMuted)
                    CountingBytesText(bytes: shownFreed, finalBytes: freedBytes ?? 0)
                        .font(Theme.display(48))
                        .tracking(-1.5)
                        .monospacedDigit()
                        .foregroundStyle(Theme.mint)
                }
            } else {
                // Opened from the sidebar or About (MenuSupportStates: heart.circle.fill 44 pt in mint).
                Image(systemName: "heart.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.mint)
            }
            if lifetimeBytes > 0 {
                Text("\(FileSizeHelper.formatBytes(lifetimeBytes)) since you started using Furl")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.pineMuted)
                    .opacity(lifetimeOpacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 26)
        .background(Theme.pine)
        // SupportDark: 1px inset pineBorder-coloured stroke on the pine header, dark mode only.
        .overlay(Rectangle().strokeBorder(Theme.heroStroke, lineWidth: 1))
    }

    /// Count-up 900 ms ease-out cubic, then the lifetime line fades in over 200 ms, then 200 ms later the
    /// suggestion line's mint wash (35% → 0 over 900 ms). Reduce Motion: final value at once, no wash.
    private func startCountUp() {
        guard let freedBytes, stage == .picker, shownFreed == 0 else { return }
        let target = Double(freedBytes)
        if reduceMotion {
            shownFreed = target
            withAnimation(.easeOut(duration: 0.2)) { lifetimeOpacity = 1 }
            return
        }
        withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.9)) {
            shownFreed = target
        } completion: {
            withAnimation(.easeOut(duration: 0.2)) { lifetimeOpacity = 1 }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                washTrigger += 1
            }
        }
    }

    // MARK: Amount picker

    private var picker: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Support Furl, pay what you like")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text("Furl is free and open source. Every feature stays unlocked whatever you choose, including nothing.")
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ForEach(SupportConfig.amounts, id: \.self) { value in
                        amountChip(value)
                    }
                    otherField
                }
                if otherOutOfRange {
                    Text("Enter a whole number from \(SupportConfig.currencySymbol)1 to \(SupportConfig.currencySymbol)\(SupportConfig.maximumAmount.formatted()).")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.danger)
                }
            }

            suggestionLine

            Button {
                pay()
            } label: {
                PayLabel(amount: chosenAmount, reduceMotion: reduceMotion)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PayButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(chosenAmount == nil || !store.isCheckoutConfigured)
            .help(store.isCheckoutConfigured
                  ? "Opens the secure checkout in your browser"
                  : "Checkout isn't set up yet")

            HStack(spacing: 12) {
                Button {
                    close()
                } label: {
                    Text("Keep using it free")
                        .font(.system(size: 13))
                        .underline()
                        .foregroundStyle(Theme.inkTertiary)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                // Support board: Keep … Asks spread apart; with the link (MenuSupportStates) Asks sits after Keep.
                if store.hasPaid { Spacer() }
                Text("Asks at most once a month")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
                if !store.hasPaid {
                    Spacer()
                    // MenuSupportStates: "I've already paid", 12 pt sweep link.
                    Button("I've already paid") {
                        store.markPaid()
                        close()
                    }
                    .buttonStyle(SweepLinkStyle())
                    .font(.system(size: 12))
                    .help("Furl won't ask again")
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
    }

    /// The count leads the eye here: a soft mint wash (35% → 0, 900 ms ease-out) 200 ms after landing.
    private var suggestionLine: some View {
        Text("Suggested: about $1 for every 10 GB you've freed.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .keyframeAnimator(initialValue: 0.0, trigger: washTrigger) { content, wash in
                content.background(Theme.mint.opacity(wash), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } keyframes: { _ in
                KeyframeTrack {
                    MoveKeyframe(0.35)
                    LinearKeyframe(0.0, duration: 0.9, timingCurve: .easeOut)
                }
            }
            .padding(.horizontal, -6)
            .padding(.vertical, -2)
    }

    private func amountChip(_ value: Int) -> some View {
        let on = !usingOther && amount == value
        return Button {
            select(value)
        } label: {
            Text("\(SupportConfig.currencySymbol)\(value)")
                .font(.system(size: 15, weight: on ? .bold : .semibold))
                .monospacedDigit()
                .foregroundStyle(on ? Theme.sweepDeep : Theme.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
        }
        .buttonStyle(AmountChipStyle(isOn: on, reduceMotion: reduceMotion))
        .focused($focusedChip, equals: value)
        .onKeyPress(.leftArrow) { moveSelection(from: value, by: -1) }
        .onKeyPress(.rightArrow) { moveSelection(from: value, by: 1) }
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func select(_ value: Int) {
        usingOther = false
        otherFocused = false
        amount = value
    }

    /// Arrow keys move the selection between chips (motion spec: "Click or arrow keys").
    private func moveSelection(from value: Int, by step: Int) -> KeyPress.Result {
        let amounts = SupportConfig.amounts
        guard let index = amounts.firstIndex(of: value) else { return .ignored }
        let next = index + step
        guard amounts.indices.contains(next) else { return .ignored }
        select(amounts[next])
        focusedChip = amounts[next]
        return .handled
    }

    private var otherField: some View {
        let valid: Bool = { if case .valid = otherState { return true }; return false }()
        let border: Color = otherOutOfRange ? Theme.danger : (usingOther ? Theme.sweep : Theme.controlBorder)
        return HStack(spacing: 2) {
            Text(SupportConfig.currencySymbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
            TextField("Other", text: $otherText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink)
                .focused($otherFocused)
                .accessibilityLabel("Other amount")
                .onChange(of: otherText) { _, newValue in
                    let digits = newValue.filter(\.isNumber)
                    if digits != newValue { otherText = digits }
                    if !digits.isEmpty { usingOther = true }
                }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        // Focused/empty and out of range stay on the surface; a valid typed amount gets the selected fill.
        .background(usingOther && valid ? Theme.amountSelected : Theme.surface,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(border, lineWidth: usingOther ? 2 : 1))
        .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.16), value: usingOther)
        .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.16), value: valid)
        .modifier(SelectionRingEffect(trigger: otherRingTrigger, enabled: !reduceMotion))
        .scaleEffect(otherPressed && !reduceMotion ? 0.97 : 1)
        .animation(.easeOut(duration: 0.09), value: otherPressed)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !otherPressed { otherPressed = true } }
                // Clicking the field deselects the chips (Other amount board). Driven by the click, not by
                // focus, because AppKit hands the field focus when the sheet opens.
                .onEnded { _ in otherPressed = false; otherFocused = true; usingOther = true }
        )
        .onChange(of: usingOther) { _, nowUsing in
            if nowUsing { otherRingTrigger += 1 }
        }
    }

    // MARK: After opening checkout

    private var checkoutOpened: some View {
        VStack(spacing: 12) {
            Text("Thank you!")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text("The checkout opened in your browser. Once you've paid, tell Furl so it never asks again.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            HStack(spacing: 10) {
                Button("Not yet") { close() }
                    .buttonStyle(SweepButtonStyle(kind: .secondary, height: 28))
                    .fixedSize()
                Button("I've paid") { showPaidThanks() }
                    .buttonStyle(SweepButtonStyle(kind: .primary, height: 28))
                    .fixedSize()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }

    // MARK: Thank you: the furl

    private var furlHeader: some View {
        ZStack {
            Theme.pine
            if reduceMotion {
                FurlCelebration(elapsed: FurlCelebration.duration)
                    .opacity(reducedMarkOpacity)
            } else if let paidAt {
                TimelineView(.animation(paused: furlFinished)) { context in
                    FurlCelebration(elapsed: furlFinished ? FurlCelebration.duration
                                                          : context.date.timeIntervalSince(paidAt))
                }
            }
        }
        .frame(height: 190)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(Rectangle().strokeBorder(Theme.heroStroke, lineWidth: 1))
        .accessibilityHidden(true)
    }

    private var paidThanks: some View {
        VStack(spacing: 8) {
            Text("Thank you for supporting Furl")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.ink)
            Text("Furl won't ask again. Your support keeps it free and open source for everyone.")
                .font(.system(size: 13))
                .lineSpacing(4)
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            Button("Done") { close() }
                .buttonStyle(DoneButtonStyle())
                .keyboardShortcut(.defaultAction)
                .padding(.top, 10)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity)
    }

    // MARK: Actions

    private func pay() {
        guard let chosenAmount, let url = store.checkoutURL(amount: chosenAmount) else { return }
        NSWorkspace.shared.open(url)
        stage = .checkoutOpened
    }

    /// "I've paid": mark the store as paid now (so Furl never asks again even if the window goes away),
    /// but keep the sheet up for the thank-you; it only closes on Done.
    private func showPaidThanks() {
        store.markPaid(clearPrompt: false)
        paidAt = Date()
        stage = .paid
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) { reducedMarkOpacity = 1 }
        } else {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(FurlCelebration.duration + 0.05))
                furlFinished = true
            }
        }
    }

    private func close() {
        store.dismissPrompt()
        dismiss()
    }
}

// MARK: - Count-up text

/// The freed number while it counts. Units switch once (MB → GB) as the value passes 1 GB;
/// the landed value is formatted exactly like everywhere else.
private struct CountingBytesText: View, Animatable {
    var bytes: Double
    let finalBytes: Int64

    nonisolated var animatableData: Double {
        get { bytes }
        set { bytes = newValue }
    }

    var body: some View {
        Text(label)
    }

    private var label: String {
        let value = Int64(bytes.rounded())
        if value >= finalBytes { return FileSizeHelper.formatBytes(finalBytes) }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: max(0, value))
    }
}

// MARK: - Pay label with digit roll

/// "Pay $X securely". When the amount changes the old number slides up and out and the new one slides
/// up from below: 180 ms ease-out, 20 pt. Reduce Motion: the label changes in place.
private struct PayLabel: View {
    let amount: Int?
    let reduceMotion: Bool

    var body: some View {
        if let amount {
            HStack(spacing: 0) {
                Text("Pay \(SupportConfig.currencySymbol)")
                ZStack {
                    Text("\(amount)")
                        .id(amount)
                        .transition(reduceMotion ? .identity : .asymmetric(
                            insertion: .offset(y: 20).combined(with: .opacity),
                            removal: .offset(y: -20).combined(with: .opacity)))
                }
                .clipped()
                Text(" securely")
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: amount)
            .accessibilityElement(children: .combine)
        } else {
            Text("Pick an amount")
        }
    }
}

// MARK: - Chip reaction (the same for every chip and Other)

/// Rest / hover (border inkSecondary, fill surfaceSubtle) / press (scale 0.97, 90 ms) / select
/// (fill and border cross-fade, 160 ms) / ring (0 → 6 pt, 28% → 0, 270 ms). Reduce Motion:
/// 120 ms cross-fade, no scale, no ring.
private struct AmountChipStyle: ButtonStyle {
    let isOn: Bool
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        Chip(configuration: configuration, isOn: isOn, reduceMotion: reduceMotion)
    }

    private struct Chip: View {
        let configuration: ButtonStyle.Configuration
        let isOn: Bool
        let reduceMotion: Bool
        @State private var hovering = false
        @State private var ringTrigger = 0

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            configuration.label
                .background(isOn ? Theme.amountSelected : (hovering ? Theme.surfaceSubtle : Theme.surface), in: shape)
                .overlay(shape.strokeBorder(isOn ? Theme.sweep : (hovering ? Theme.inkSecondary : Theme.controlBorder),
                                            lineWidth: isOn ? 2 : 1))
                .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.16), value: isOn)
                .modifier(SelectionRingEffect(trigger: ringTrigger, enabled: !reduceMotion))
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
                .contentShape(shape)
                .onHover { hovering = $0 }
                .onChange(of: isOn) { _, on in
                    if on { ringTrigger += 1 }
                }
        }
    }
}

/// The sweep ring that grows 0 → 6 pt outside the chip and fades 28% → 0 over 270 ms ease-out.
private struct SelectionRingEffect: ViewModifier {
    let trigger: Int
    let enabled: Bool

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 1.0, trigger: trigger) { view, progress in
            view.overlay {
                if enabled && progress < 1 {
                    let width = 6 * progress
                    RoundedRectangle(cornerRadius: 10 + width / 2, style: .continuous)
                        .stroke(Theme.sweep.opacity(0.28 * (1 - progress)), lineWidth: width)
                        .padding(-width / 2)
                        .allowsHitTesting(false)
                }
            }
        } keyframes: { _ in
            KeyframeTrack {
                MoveKeyframe(0.0)
                LinearKeyframe(1.0, duration: 0.27, timingCurve: .easeOut)
            }
        }
    }
}

// MARK: - The furl

/// The thank-you header drawing at a given time since "I've paid" (PayWhatYouLike board, "Thank you: the furl"):
/// the Curl f draws itself and 18 confetti pieces burst out and are gone by 1.2 s. Drawn on the hero header only.
private struct FurlCelebration: View {
    static let duration: TimeInterval = 1.2

    let elapsed: TimeInterval

    // Confetti, from the board's 600 ms and 1,200 ms frames (viewBox units around the mark centre).
    private static let startRadii: [Double] = [34.9, 38.1, 41.2]
    private static let endRadii: [Double] = [44, 53, 62]
    /// The board's confetti cycle: mint, light, warm yellow, sky, mint, pink.
    private static let confetti: [Color] = [
        Theme.mint, Color(nsColor: NSColor(hex: 0xF2F2EE)), Color(nsColor: NSColor(hex: 0xFFD27A)),
        Color(nsColor: NSColor(hex: 0x7FB8FF)), Theme.mint, Color(nsColor: NSColor(hex: 0xF7A1C4)),
    ]

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
    }

    /// PayWhatYouLike board: the f is drawn (stem 0–400 ms ease-in-out, bar 300–500 ms), the curl rolls
    /// up (450–800 ms, ease-out) in the theme accent, confetti bursts 600–1,200 ms. The finished Curl f stays.
    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let ms = max(0, elapsed * 1000)
        // The mark is 154 pt wide for a 102-unit viewBox (-19…83), centred in the header.
        let scale = 154.0 / 102.0
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let origin = CGPoint(x: center.x - 32 * scale, y: center.y - 32 * scale)

        if ms >= 600 && ms < 1200 {
            let t = (ms - 600) / 600
            let travel = easeOutCubic(t)
            let opacity = t < 0.5 ? 1 : 1 - (t - 0.5) / 0.5
            for i in 0..<18 {
                let angle = Double(7 + 20 * i) * .pi / 180
                let r0 = Self.startRadii[i % 3], r1 = Self.endRadii[i % 3]
                let r = (r0 + (r1 - r0) * travel) * scale
                let p = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
                let rotation = Double(14 + 40 * i) + 90 * travel
                var piece = context
                piece.opacity = opacity
                piece.translateBy(x: p.x, y: p.y)
                piece.rotate(by: .degrees(rotation))
                let rect = CGRect(x: -1.4 * scale, y: -0.8 * scale, width: 2.8 * scale, height: 1.6 * scale)
                piece.fill(Path(roundedRect: rect, cornerRadius: 0.5 * scale), with: .color(Self.confetti[i % Self.confetti.count]))
            }
        }

        let shape = SweepMarkRenderer.paths(glyph: false, scale: scale, origin: origin)
        let stroke = StrokeStyle(lineWidth: shape.lineWidth, lineCap: .round, lineJoin: .round)
        // Dim track of the whole mark under everything.
        for path in [shape.f, shape.curl, shape.bar] {
            context.stroke(path, with: .color(Theme.pineTrack), style: stroke)
        }
        let stem = easeInOutCubic(min(ms / 400, 1))
        let bar = min(max((ms - 300) / 200, 0), 1)
        let curl = easeOutCubic(min(max((ms - 450) / 350, 0), 1))
        if stem > 0 { context.stroke(shape.f.trimmedPath(from: 0, to: stem), with: .color(Theme.onPine), style: stroke) }
        if bar > 0 { context.stroke(shape.bar.trimmedPath(from: 0, to: bar), with: .color(Theme.onPine), style: stroke) }
        if curl > 0 { context.stroke(shape.curl.trimmedPath(from: 0, to: curl), with: .color(Theme.mint), style: stroke) }
    }

    private func easeInOutCubic(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    private func easeOutCubic(_ t: Double) -> Double {
        1 - pow(1 - t, 3)
    }
}

// MARK: - Buttons

/// "Pay $12 securely": 46pt, radius 12, 15pt bold on sweep (Support board).
private struct PayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PayButton(configuration: configuration)
    }

    private struct PayButton: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 15, weight: .bold))
                .lineLimit(1)
                // Disabled ("Pick an amount"): sweepDeep on mintTint, not a faded fill, so the label stays
                // readable in light and dark (7.1:1 / 9.1:1).
                .foregroundStyle(isEnabled ? Theme.onSweep : Theme.sweepDeep)
                .frame(height: 46)
                .background(isEnabled ? Theme.sweep : Theme.mintTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .opacity(isEnabled && configuration.isPressed ? 0.82 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// Thank-you "Done": primary, 32 high, padding 14, radius 9, 13 semibold (PayWhatYouLike board).
private struct DoneButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(Theme.onSweep)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Theme.sweep, in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
    }
}
