import AppKit
import SwiftUI

/// "Version 1.0 (42)", shared by About and Settings › General › Help.
enum AboutVersion {
    static var label: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?) where build != short: return "Version \(short) (\(build))"
        case let (short?, _): return "Version \(short)"
        default: return "Development build"
        }
    }
}

/// Content for the About window. The app wires it into a `Window` scene and passes `onSupport`
/// to open the support sheet and `onReportProblem` to open Report a Problem.
struct AboutView: View {
    var onSupport: () -> Void = {}
    var onReportProblem: () -> Void = {}
    @ObservedObject private var updates = UpdateChecker.shared

    private var version: String { AboutVersion.label }

    var body: some View {
        VStack(spacing: 16) {
            appMark

            VStack(spacing: 6) {
                Text("Furl")
                    .font(Theme.display(22))
                Text("\(version) · Free and open source")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
                    .textSelection(.enabled)
            }

            // UpdateCheck board: the slot under the version line. Nothing is fetched until the user clicks.
            UpdateSlot(checker: updates)

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.sweep)
                Text("Private by default. No account. Your files never leave your Mac.")
                    .font(.system(size: 12))
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.sweep.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(spacing: 6) {
                linkRow("Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right", url: SupportConfig.githubURL)
                linkRow("Website", systemImage: "globe", url: SupportConfig.websiteURL)
                // Opens the Report a Problem sheet (chevron, ellipsis) instead of linking to GitHub Issues.
                Button(action: onReportProblem) {
                    HStack {
                        Label("Report a Problem…", systemImage: "exclamationmark.bubble")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }

            Button(action: onSupport) {
                Label("Support Furl", systemImage: "heart")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SweepButtonStyle(kind: .primary, height: 38, fullWidth: true))
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 28)
        .frame(width: 340)
        // The result stays until About closes; next time the slot is idle again.
        .onDisappear { updates.reset() }
    }

    /// The app icon when bundled (it follows the theme's curl, see `DockIcon`); the Curl f tile
    /// under `swift run`.
    @ViewBuilder
    private var appMark: some View {
        if Bundle.main.bundleURL.pathExtension == "app" {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
        } else {
            SweepMark(style: .tile)
                .frame(width: 70, height: 70)
                .frame(width: 88, height: 88)
        }
    }

    private func linkRow(_ title: String, systemImage: String, url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .help(url.absoluteString)
    }
}

/// The update slot in About (UpdateCheck board): idle, checking, up to date, a newer version,
/// offline, and GitHub refused.
private struct UpdateSlot: View {
    @ObservedObject var checker: UpdateChecker

    private var current: String { UpdateChecker.currentVersion }

    var body: some View {
        switch checker.status {
        case .idle:
            checkButton("Check for Updates")
        case .checking:
            HStack(spacing: 8) {
                UpdateSpinner()
                Text("Checking GitHub for a newer version…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
            }
            .frame(height: 26)
        case .upToDate:
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.sweep)
                    Text("Furl \(current) is the latest version.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.ink)
                }
                HStack(spacing: 5) {
                    Text("Checked just now")
                    Text("·")
                    Button("Check Again") { checker.check() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.sweep)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.inkSecondary)
            }
            .frame(minHeight: 26)
        case .available(let version, let releaseURL):
            availableCard(version: version, releaseURL: releaseURL)
        case .offline:
            VStack(spacing: 8) {
                problemLine("Couldn't reach GitHub. Check your connection.", systemImage: "wifi.slash")
                checkButton("Try Again")
            }
        case .refused:
            VStack(spacing: 6) {
                problemLine("GitHub isn't answering right now.", systemImage: "exclamationmark.triangle")
                Text("Try again in a few minutes.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkSecondary)
                checkButton("Try Again")
            }
        }
    }

    /// SweepButton secondary, 26 pt, 12 pt label, icon arrow.clockwise.
    private func checkButton(_ title: String) -> some View {
        Button { checker.check() } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .bold))
                Text(title)
            }
        }
        .buttonStyle(SweepButtonStyle(kind: .secondary, height: 26))
    }

    private func problemLine(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.warning)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink)
        }
    }

    /// Card: mintTint, radius 10, padding 12 × 14. Title sweepDeep 13 semibold; body 12 inkTertiary;
    /// Download is primary 28.
    private func availableCard(version: String, releaseURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.sweepDeep)
                Text("Version \(version) is available")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.sweepDeep)
            }
            Text("You have \(current). Download the new version and drag it into Applications to replace this one. Your settings and history stay.")
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                // Opens the release page (html_url) in the browser.
                Button { NSWorkspace.shared.open(releaseURL) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .bold))
                        Text("Download")
                    }
                }
                .buttonStyle(SweepButtonStyle(kind: .primary, height: 28))
                .help(releaseURL.absoluteString)

                Button("What's New") { NSWorkspace.shared.open(SupportConfig.changelogURL(version: version)) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.sweep)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 12)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.mintTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Spinner 13 pt: a sweep arc on a 20% sweep track, one turn per second. Still under Reduce Motion.
private struct UpdateSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let turns = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            ZStack {
                Circle()
                    .stroke(Theme.sweep.opacity(0.2), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(Theme.sweep, style: StrokeStyle(lineWidth: 2, lineCap: .butt))
                    .rotationEffect(.degrees(-135 + turns * 360))
            }
            .padding(1)
        }
        .frame(width: 13, height: 13)
        .accessibilityHidden(true)
    }
}
