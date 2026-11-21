import SwiftUI

/// One calm mint line about Full Disk Access: icon, message, buttons, ✕. The after-update banner
/// (UpdatePermissions) and the limited-results line (WelcomeAccess) are this component with
/// different words; never warning orange, because nothing is broken, Furl only sees less.
struct FullDiskAccessNotice<Message: View, Actions: View>: View {
    var systemImage: String
    var dismissLabel: String
    var onDismiss: () -> Void
    @ViewBuilder var message: () -> Message
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.sweepDeep)
            message()
                .foregroundStyle(Theme.sweepDeep)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            actions()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.sweepDeep)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dismissLabel)
            .help(dismissLabel)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(Theme.mintTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// The limited-results line for one screen: shown while Full Disk Access is off, hidden by ✕ on
/// that screen until the next version. Its button opens Settings › Permissions, which has the steps.
struct LimitedResultsLine: View {
    let screen: LimitedResultsScreen
    /// Only once the screen has results; before that there are no totals to call low.
    var hasResults: Bool = true
    /// List screens put the line in its own padded row under the header; the Overview places it
    /// inside its page padding.
    var padded: Bool = true
    @ObservedObject private var fullDiskAccess = FullDiskAccess.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if hasResults && fullDiskAccess.showsLimitedLine(on: screen) {
            FullDiskAccessNotice(
                systemImage: "eye",
                dismissLabel: "Hide for this version",
                onDismiss: { fullDiskAccess.dismissLimitedLine(on: screen) },
                message: { Text(screen.message) },
                actions: {
                    Button(screen.buttonTitle) {
                        SettingsTab.select(.permissions)
                        AppWindows.activateForWindow()
                        openSettings()
                    }
                    .buttonStyle(SweepLinkStyle())
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize()
                }
            )
            .padding(.horizontal, padded ? Theme.Space.page : 0)
            .padding(.top, padded ? 14 : 0)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                fullDiskAccess.refresh()
            }
        }
    }
}
