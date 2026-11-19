import AppKit
import SwiftUI

/// "Recommended tools" card on the Compress page (OptionalTools board). Only appears after a scan, and only for
/// tools whose files the scan actually found. Installs with `brew install` on click; never installs Homebrew itself.
struct OptionalToolsCard: View {
    /// Tools the last scan recommends (already minus "Not now").
    let recommended: [OptionalTool]
    let finds: [OptionalTool: ToolFind]
    let isRescanning: Bool
    /// A scan or compress run is in flight: a new install now would race its tool detection, so Install waits.
    let installsBlocked: Bool
    /// Estimate for the categories the new tools work on, before the install and after the rescan. Only those
    /// categories are compared: the whole-page estimate also moves with sampling noise in unrelated categories.
    let estimateChange: (categories: [CompressCategory], before: Int64, after: Int64)?
    let onNotNow: () -> Void
    let onClose: () -> Void

    @ObservedObject private var installer = ToolInstaller.shared
    @State private var showOutput = false

    /// Rows: the recommendation plus anything the installer touched from this page (e.g. via a category link).
    private var tools: [OptionalTool] {
        OptionalTool.lossless.filter { recommended.contains($0) || installer.state($0) != nil }
    }

    private var touched: [OptionalTool] { tools.filter { installer.state($0) != nil } }
    private var failed: [OptionalTool] { touched.filter { installer.state($0) == .failed } }
    private var missing: [OptionalTool] { tools.filter { installer.state($0) != .installed } }
    private var hasBrew: Bool { ToolInstaller.brewPath != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !hasBrew {
                noHomebrew
            } else if installer.isRunning && !touched.isEmpty {
                installing
            } else if !failed.isEmpty {
                failedState
            } else if !touched.isEmpty && missing.isEmpty {
                doneState
            } else {
                recommendation
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 0)
    }

    // MARK: States

    private var recommendation: some View {
        Group {
            header(icon: "wrench.adjustable", fg: Theme.sweep, bg: Theme.mintTint,
                   title: "\(missing.count) free \(missing.count == 1 ? "tool" : "tools") would handle files this scan had to skip",
                   subtitle: "Only tools that match what was found on this Mac are listed.") {
                Button("Not now", action: onNotNow)
                    .buttonStyle(SweepLinkStyle())
                    .font(Theme.caption)
                    .disabled(installer.isRunning)
            }
            rows
            HStack(spacing: 12) {
                Text("Free tools from Homebrew, installed in your user account. No admin password; Furl never bundles them.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                copyButton(OptionalTool.installCommand(missing), title: "Copy command")
                Button(missing.count == 1 ? "Install" : "Install all \(missing.count)") { installer.install(missing) }
                    .buttonStyle(SweepButtonStyle(kind: .primary, height: 30))
                    .font(Theme.caption.weight(.semibold))
                    .fixedSize()
                    .disabled(installer.isRunning || missing.isEmpty || installsBlocked)
            }
        }
    }

    private var installing: some View {
        let queue = touched
        let done = queue.filter { [.installed, .failed].contains(installer.state($0)) }.count
        let current = installer.current
        return Group {
            header(icon: "wrench.adjustable", fg: Theme.sweep, bg: Theme.mintTint,
                   title: current.map { "Installing \(min(done + 1, queue.count)) of \(queue.count): \($0.formula)" } ?? "Installing…",
                   subtitle: "Homebrew is downloading and installing. This usually takes under a minute.") {
                CancelRunButton(compact: true) { installer.cancel() }
            }
            MeterBar(fraction: queue.isEmpty ? 0 : (Double(done) + 0.4) / Double(queue.count),
                     color: Theme.sweep, track: Theme.mintTint, height: 6)
            rows
            outputDisclosure
        }
    }

    @ViewBuilder
    private var doneState: some View {
        if isRescanning {
            header(icon: "checkmark", fg: Theme.sweep, bg: Theme.mintTint,
                   title: "Installed " + listJoined(touched.map(\.formula)),
                   subtitle: "Scanning again so the new formats are counted.") {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Scanning…").font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                }
            }
        } else {
            let count = touched.count
            let tools = count == 1 ? (touched.first?.formula ?? "1 tool") : "\(count) tools"
            header(icon: "checkmark", fg: Theme.sweep, bg: Theme.mintTint,
                   title: estimateChange.map { "Installed \(tools). " + changeText($0) } ?? "Installed \(tools)",
                   subtitle: estimateChange == nil
                       ? "Scan again to include the new formats."
                       : "Only the formats these tools handle are compared, measured on a sample of your files.") {
                Button("Close", action: onClose)
                    .buttonStyle(SweepButtonStyle(kind: .secondary, height: 28))
                    .font(Theme.caption)
                    .fixedSize()
            }
        }
    }

    private var failedState: some View {
        let others = touched.filter { installer.state($0) == .installed }.count
        return Group {
            header(icon: "exclamationmark.triangle", fg: Theme.danger, bg: Theme.dangerTint,
                   title: "\(listJoined(failed.map(\.formula))) didn’t install",
                   subtitle: (others > 0 ? "The other \(others) \(others == 1 ? "is" : "are") installed and in use. " : "")
                       + (installer.wasCancelled ? "Install was cancelled." : "Homebrew’s message is below, exactly as it said it.")) {
                Button("Try again") { installer.install(failed) }
                    .buttonStyle(SweepButtonStyle(kind: .primary, height: 28))
                    .font(Theme.caption.weight(.semibold))
                    .fixedSize()
            }
            rows
            if let error = installer.lastError, !installer.wasCancelled {
                logBox(error, color: Theme.danger)
            }
            HStack(spacing: 12) {
                Text("You can also run it in Terminal to see the full output.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                copyButton(OptionalTool.installCommand(failed), title: "Copy command")
                Button(showOutput ? "Hide full output" : "Show full output") { showOutput.toggle() }
                    .buttonStyle(SweepButtonStyle(kind: .secondary, height: 28))
                    .font(Theme.caption)
                    .fixedSize()
            }
            if showOutput { logBox(installer.output.joined(separator: "\n"), color: Theme.inkTertiary, maxHeight: 220) }
        }
    }

    private var noHomebrew: some View {
        let command = OptionalTool.installCommand(missing.isEmpty ? tools : missing)
        return Group {
            header(icon: "exclamationmark.triangle", fg: Theme.warning, bg: Theme.warningTint,
                   title: "These tools come from Homebrew, which isn’t installed",
                   subtitle: "Installing Homebrew itself needs your admin password, so Furl leaves that step to you. Once it’s installed, come back and click Install.") {
                HStack(spacing: 8) {
                    Button {
                        if let url = URL(string: "https://brew.sh") { NSWorkspace.shared.open(url) }
                    } label: {
                        Label("Open brew.sh", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(SweepButtonStyle(kind: .secondary, height: 28))
                    .font(Theme.caption)
                    .fixedSize()
                    Button("Not now", action: onNotNow)
                        .buttonStyle(SweepLinkStyle())
                        .font(Theme.caption)
                }
            }
            Text("Or, after installing Homebrew, run this in Terminal:")
                .font(Theme.caption)
                .foregroundStyle(Theme.inkSecondary)
            HStack(spacing: 8) {
                commandText(command)
                copyButton(command, title: "Copy")
            }
        }
    }

    // MARK: Pieces

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(tools.enumerated()), id: \.element) { index, tool in
                row(tool, last: index == tools.count - 1)
            }
        }
    }

    private func row(_ tool: OptionalTool, last: Bool) -> some View {
        HStack(spacing: 12) {
            Text(tool.formula)
                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .frame(width: 130, alignment: .leading)
            Text(tool.detail)
                .font(Theme.caption)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(foundText(tool))
                .font(Theme.caption.monospacedDigit())
                .foregroundStyle(Theme.inkTertiary)
                .frame(width: 190, alignment: .leading)
            rowStatus(tool)
                .frame(width: 130, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Theme.hairline).frame(height: 1) } }
    }

    @ViewBuilder
    private func rowStatus(_ tool: OptionalTool) -> some View {
        switch installer.state(tool) {
        case .installed:
            ShrinkCapsBadge(text: "INSTALLED", fg: Theme.sweep, bg: Theme.mintTint)
        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.8)
                Text("Installing…").font(Theme.caption).foregroundStyle(Theme.inkTertiary)
            }
        case .waiting:
            Text("Waiting").font(Theme.caption).foregroundStyle(Theme.inkSecondary)
        case .failed:
            ShrinkCapsBadge(text: "DIDN’T INSTALL", fg: Theme.danger, bg: Theme.dangerTint)
        case nil:
            Button("Install") { installer.install([tool]) }
                .buttonStyle(SweepButtonStyle(kind: .secondary, height: 28))
                .font(Theme.caption)
                .fixedSize()
                .disabled(installer.isRunning || !hasBrew || installsBlocked)
        }
    }

    private func foundText(_ tool: OptionalTool) -> String {
        if tool == .zopfli, tools.contains(.oxipng), finds[.oxipng] != nil { return "Same PNGs" }
        return finds[tool]?.summary ?? ""
    }

    private var outputDisclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showOutput.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showOutput ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(width: 10)
                    Text("Homebrew output").font(Theme.caption).foregroundStyle(Theme.ink)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showOutput {
                logBox(installer.output.suffix(60).joined(separator: "\n"), color: Theme.inkTertiary, maxHeight: 160)
            } else if let last = installer.output.last {
                Text(last)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 16)
            }
        }
    }

    private func logBox(_ text: String, color: Color, maxHeight: CGFloat? = nil) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(color)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: maxHeight == nil)
        .background(Theme.hairline.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private func header<Trailing: View>(icon: String, fg: Color, bg: Color, title: String, subtitle: String,
                                        @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(fg)
                .frame(width: 32, height: 32)
                .background(bg, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                Text(subtitle)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
    }

    private func commandText(_ command: String) -> some View {
        Text(command)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Theme.ink)
            .textSelection(.enabled)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(Theme.hairline, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func copyButton(_ command: String, title: String) -> some View {
        Button(title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
        .buttonStyle(SweepButtonStyle(kind: .secondary, height: 28))
        .font(Theme.caption)
        .fixedSize()
    }

    private func changeText(_ change: (categories: [CompressCategory], before: Int64, after: Int64)) -> String {
        let names = listJoined(change.categories.map(\.title))
        let after = FileSizeHelper.formatBytes(change.after)
        let before = FileSizeHelper.formatBytes(change.before)
        if after == before { return "\(names) save about \(after), the same as before" }
        return change.after > change.before
            ? "\(names) now save about \(after), up from \(before)"
            : "\(names) now save about \(after), down from \(before)"
    }

    private func listJoined(_ items: [String]) -> String {
        ListFormatter.localizedString(byJoining: items)
    }
}
