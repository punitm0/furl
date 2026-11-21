import SwiftUI

/// LeftoversWhatsNew board, "What's new in 1.4.0": app icon, title, one sentence per change with a
/// dot, then "Full changelog" (opens the website) and OK.
struct WhatsNewSheet: View {
    let notes: WhatsNew.Notes
    let onChangelog: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What\u{2019}s new in \(notes.version)")
                        .font(Theme.display(20, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("Shown once after updating")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(notes.lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(Theme.sweep)
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)
                            .accessibilityHidden(true)
                        Text(line)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.ink)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 8)
                    .overlay(alignment: .top) {
                        if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    }
                }
            }
            HStack(spacing: 8) {
                Button("Full changelog", action: onChangelog)
                    .buttonStyle(SweepLinkStyle())
                    .font(.system(size: 13, weight: .medium))
                    .help(WhatsNew.changelogURL.absoluteString)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Text("OK").frame(minWidth: 48)
                }
                .buttonStyle(SweepButtonStyle(kind: .primary, height: 32))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(.top, 22)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(width: 460)
        .background(Theme.surface)
        .onExitCommand(perform: onClose)
    }
}
