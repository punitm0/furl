import AppKit
import SwiftUI

/// Presents Report a Problem as a sheet on the main window, from Help › Report a Problem…,
/// Settings › General › Help and About.
@MainActor
final class ReportProblemStore: ObservableObject {
    static let shared = ReportProblemStore()

    @Published var isPresented = false

    func present() {
        AppWindows.showMain(section: nil, state: AppServices.state)
        isPresented = true
    }
}

/// Report a Problem (ReportProblem board): an optional note, read-only diagnostics, then
/// Copy Report or Open GitHub Issue. Nothing is sent from Furl; GitHub opens in the browser.
struct ReportProblemSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var whatHappened = ""
    @State private var diagnostics = ""
    @State private var copied = false
    @State private var copiedResetTask: Task<Void, Never>?
    @State private var tooLongForLink = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            whatHappenedField
            diagnosticsBox
            if tooLongForLink {
                tooLongNote
            }
            privacyLine
            buttons
        }
        .padding(.top, 22)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(width: 540)
        .background(Theme.surface)
        .onAppear { diagnostics = DiagnosticsReport.diagnosticsText(state: state) }
        .onDisappear { copiedResetTask?.cancel() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.mintTint)
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "exclamationmark.bubble")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.sweep)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text("Report a problem")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text("Review what's below, then copy it or open a GitHub issue with it filled in. It has no file names or paths.")
                    .font(.system(size: 12))
                    .lineSpacing(2)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var whatHappenedField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What happened?")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $whatHappened)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink)
                    .scrollContentBackground(.hidden)
                    .lineSpacing(2)
                    // TextEditor insets its text by about 5pt; this lands it on the 8 × 10 padding.
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .accessibilityLabel("What happened?")
                if whatHappened.isEmpty {
                    Text("What did you expect, and what happened instead? (optional)")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.inkSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 58, maxHeight: 58)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.controlBorder, lineWidth: 1)
            )
        }
    }

    private var diagnosticsBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Diagnostics")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("Read only · select to copy part of it")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkSecondary)
            }
            ScrollView {
                Text(diagnostics)
                    .font(.system(size: 11.5, design: .monospaced))
                    // 11.5 pt at a 1.55 line height.
                    .lineSpacing(11.5 * 0.55 - 2)
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
            }
            .frame(height: 354)
            .background(Theme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.controlBorder, lineWidth: 1)
            )
        }
    }

    private var tooLongNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.warning)
            Text("This report is too long for a link, so it's on your clipboard. In the issue that just opened, paste it under \(Text("Diagnostics").bold()).")
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .background(Theme.warningTint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var privacyLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
            Text("Nothing is sent from Furl. GitHub opens in your browser, where you can edit before posting.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(SweepButtonStyle(kind: .secondary, height: 32))
                .keyboardShortcut(.cancelAction)

            Button(action: copyReport) {
                if copied {
                    Label("Copied", systemImage: "checkmark")
                        .foregroundStyle(Theme.sweep)
                } else {
                    Label("Copy Report", systemImage: "doc.on.doc")
                }
            }
            .buttonStyle(SweepButtonStyle(kind: .secondary, height: 32))

            Button(action: openIssue) {
                Label("Open GitHub Issue", systemImage: "arrow.up.right")
            }
            .buttonStyle(SweepButtonStyle(kind: .primary, height: 32))
            .keyboardShortcut(.defaultAction)
        }
        .labelStyle(SmallIconLabelStyle())
    }

    // MARK: - Actions

    private var reportMarkdown: String {
        DiagnosticsReport.issueBody(whatHappened: whatHappened, diagnostics: diagnostics)
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// "Copied" with a check, in sweep, for 2 s, then back to Copy Report.
    private func copyReport() {
        copyToClipboard(reportMarkdown)
        copied = true
        copiedResetTask?.cancel()
        copiedResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    /// Past 7,000 characters the link opens with only What happened; the full report goes on the clipboard.
    private func openIssue() {
        if let url = DiagnosticsReport.issueURL(body: reportMarkdown),
           url.absoluteString.count <= DiagnosticsReport.maximumURLLength {
            NSWorkspace.shared.open(url)
            tooLongForLink = false
            return
        }
        copyToClipboard(reportMarkdown)
        if let url = DiagnosticsReport.issueURL(body: DiagnosticsReport.shortIssueBody(whatHappened: whatHappened)) {
            NSWorkspace.shared.open(url)
        }
        tooLongForLink = true
    }
}

/// 12 pt icon, 6 pt gap, as the board's 32 pt buttons draw it.
private struct SmallIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .font(.system(size: 11, weight: .bold))
            configuration.title
        }
    }
}
