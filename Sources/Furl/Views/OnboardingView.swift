import AppKit
import SwiftUI

/// First run (WelcomeAccess board): Welcome with the website's two promises, then Full Disk
/// Access with the website's steps. Covers the main window until the user continues past it.
struct OnboardingView: View {
    @ObservedObject var store: OnboardingStore

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch store.step {
                case .welcome, .done:
                    WelcomeStep(store: store)
                case .fullDiskAccess:
                    AccessStep(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 40)

            StepDots(current: store.step == .fullDiskAccess ? 1 : 0)
                .padding(.bottom, 26)
        }
        .background(Theme.ground)
        .onAppear { store.resume() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.appBecameActive()
        }
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    @ObservedObject var store: OnboardingStore
    @State private var continuing = false

    var body: some View {
        VStack(spacing: 14) {
            // InstallHandoff board: "Furl is in Applications now…" sits above Welcome on the moved copy.
            InstallDoneBanner()
                .padding(.bottom, 10)
            SweepMark(style: .tile)
                .frame(width: 76, height: 76)
            Text("Welcome to Furl")
                .font(Theme.display(32, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.top, 8)
            Text("Clean what’s safe. Explain the rest.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.inkSecondary)
            VStack(spacing: 10) {
                PromiseRow(
                    systemImage: "trash",
                    title: "Goes to the Trash first",
                    detail: "By default, so you can undo. Anything that can’t use the Trash says “Permanent” and asks first."
                )
                PromiseRow(
                    systemImage: "shield",
                    title: "Your files never leave your Mac",
                    detail: "Furl works offline. File names, paths and contents stay on this Mac."
                )
            }
            .padding(.top, 14)
            Button("Continue") {
                continuing = true
                Task {
                    await store.continueFromWelcome()
                    continuing = false
                }
            }
            .buttonStyle(SweepButtonStyle(kind: .primary, height: 40))
            .frame(minWidth: 200)
            .keyboardShortcut(.defaultAction)
            .disabled(continuing)
            .padding(.top, 16)
        }
        .frame(width: 520)
        .multilineTextAlignment(.center)
    }
}

private struct PromiseRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.sweep)
                .frame(width: 36, height: 36)
                .background(Theme.mintTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(Theme.body)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}

// MARK: - Full Disk Access

private struct AccessStep: View {
    @ObservedObject var store: OnboardingStore

    var body: some View {
        Group {
            switch store.access {
            case .intro:
                intro
            case .waiting:
                StateCard(symbol: "lock", tint: Theme.memory, tile: Theme.memoryTint, title: "Waiting for Full Disk Access",
                          detail: "Turn on Furl in System Settings. Furl checks every few seconds.") {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting…")
                    }
                    .font(Theme.bodyStrong)
                    .foregroundStyle(Theme.sweepDeep)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(Theme.mintTint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    continueWithout(.link)
                }
            case .on:
                StateCard(symbol: "checkmark", tint: Theme.sweep, tile: Theme.mintTint, title: "Full Disk Access is on",
                          detail: "Furl can see the whole disk now.") {
                    Button("Continue") { store.finish() }
                        .buttonStyle(SweepButtonStyle(kind: .primary, height: 34, fullWidth: true))
                        .keyboardShortcut(.defaultAction)
                }
            case .almostThere:
                StateCard(symbol: "clock", tint: Theme.sweep, tile: Theme.mintTint, title: "Almost there",
                          detail: "macOS turns it on once Furl reopens.") {
                    Button("Reopen Furl") { store.reopenFurl() }
                        .buttonStyle(SweepButtonStyle(kind: .primary, height: 34, fullWidth: true))
                        .keyboardShortcut(.defaultAction)
                    continueWithout(.button)
                }
            case .stillOff:
                // Calm, not an error: grey tile, no orange, Continue Without It is a full button.
                StateCard(symbol: "lock", tint: Theme.inkSecondary, tile: Theme.accentGray.bg, title: "Full Disk Access is still off",
                          detail: "That’s fine. Furl works without it, but skips Mail, Safari and some app data, so totals will be lower.",
                          width: 340) {
                    Button("Open System Settings") { store.openSystemSettings() }
                        .buttonStyle(SweepButtonStyle(kind: .primary, height: 34, fullWidth: true))
                    continueWithout(.button)
                    Text("Not in the list? Click + and choose Furl in Applications.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.access)
    }

    private enum ContinueStyle { case link, button }

    @ViewBuilder
    private func continueWithout(_ style: ContinueStyle) -> some View {
        switch style {
        case .link:
            Button("Continue Without It") { store.finish() }
                .buttonStyle(SweepLinkStyle())
                .font(.system(size: 13, weight: .medium))
                .frame(height: 26)
        case .button:
            Button("Continue Without It") { store.finish() }
                .buttonStyle(SweepButtonStyle(kind: .secondary, height: 32, fullWidth: true))
        }
    }

    private var intro: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Theme.memory)
                .frame(width: 64, height: 64)
                .background(Theme.memoryTint, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            Text("Let Furl see the whole disk")
                .font(Theme.display(28, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.top, 6)
            Text("macOS hides Mail, Safari and some app data from every app until you allow it. Furl only reads names and sizes.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.inkSecondary)
                .lineSpacing(3)
                .frame(maxWidth: 480)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    StepRow(number: 1, title: "Click Open System Settings below.")
                    StepRow(number: 2, title: "Turn on Furl in Privacy & Security › Full Disk Access.",
                            detail: "Not in the list? Click + and choose Furl in Applications.")
                    StepRow(number: 3, title: "Come back here.",
                            detail: "Furl notices by itself. If macOS asks to reopen Furl, say yes.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1.3)
                SettingsListPicture()
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            VStack(spacing: 6) {
                Button("Open System Settings") { store.openSystemSettings() }
                    .buttonStyle(SweepButtonStyle(kind: .primary, height: 40))
                    .frame(minWidth: 220)
                    .keyboardShortcut(.defaultAction)
                continueWithout(.link)
            }
            .padding(.top, 8)
            Text("Without it, totals will be lower. You can turn it on later in Settings › Permissions.")
                .font(Theme.caption)
                .foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 560)
        .multilineTextAlignment(.center)
    }
}

private struct StepRow: View {
    let number: Int
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.sweepDeep)
                .frame(width: 22, height: 22)
                .background(Theme.mintTint, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                if let detail {
                    Text(detail)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            .padding(.top, 2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A small picture of System Settings' Full Disk Access list with Furl switched on.
private struct SettingsListPicture: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("‹ Full Disk Access")
                .foregroundStyle(Theme.inkSecondary)
            HStack(spacing: 8) {
                SweepMark(style: .tile)
                    .frame(width: 18, height: 18)
                Text("Furl")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // macOS's own switch colour, as drawn on the board.
                Capsule()
                    .fill(Color(nsColor: .systemGreen))
                    .frame(width: 30, height: 18)
                    .overlay(alignment: .trailing) {
                        Circle().fill(.white).frame(width: 14, height: 14).padding(.trailing, 2)
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            HStack(spacing: 4) {
                ForEach(["+", "−"], id: \.self) { symbol in
                    Text(symbol)
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(width: 20, height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.controlBorder, lineWidth: 1))
                }
            }
        }
        .font(Theme.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// One of the "coming back" states: icon tile, title, one line, buttons.
private struct StateCard<Actions: View>: View {
    let symbol: String
    let tint: Color
    let tile: Color
    let title: String
    let detail: String
    var width: CGFloat = 300
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 48, height: 48)
                .background(tile, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            Text(title)
                .font(Theme.display(18, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(detail)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.inkSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                actions()
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
        }
        .multilineTextAlignment(.center)
        .padding(20)
        .frame(width: width)
        .background(Theme.ground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 22, y: 12)
    }
}

private struct StepDots: View {
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Theme.sweep : Theme.controlBorder)
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of 2")
    }
}
