import Foundation

// MARK: - The optional Homebrew tools

/// Free command-line tools Compress and Shrink use when they're installed. Furl never bundles them; it installs
/// one only when the user clicks Install, with `brew install <formula>` in their own account (no sudo).
enum OptionalTool: String, CaseIterable, Identifiable, Sendable, Hashable, Codable {
    case qpdf, gifsicle, jpegTurbo, oxipng, zopfli, pngquant, mozjpeg

    var id: String { rawValue }

    /// Homebrew formula name.
    var formula: String {
        switch self {
        case .jpegTurbo: return "jpeg-turbo"
        default: return rawValue
        }
    }

    /// The command Furl actually runs, shown in the UI (jpeg-turbo provides jpegtran, zopfli provides zopflipng).
    var binaryName: String {
        switch self {
        case .jpegTurbo: return "jpegtran"
        case .zopfli: return "zopflipng"
        case .mozjpeg: return "mozjpeg"
        default: return rawValue
        }
    }

    /// What it does for the user, in one line (OptionalTools board, row text).
    var detail: String {
        switch self {
        case .qpdf: return "Optimises PDFs losslessly. Without it, PDFs are skipped."
        case .gifsicle: return "Optimises GIFs. Without it, GIFs are skipped."
        case .jpegTurbo: return "Optimises JPEGs losslessly. Without it, JPEGs are skipped."
        case .oxipng: return "Packs PNGs tighter than macOS can. On 60 test PNGs: 35% smaller, vs 6.5% with macOS alone."
        case .zopfli: return "A second, slower PNG packer: 3–8% smaller than standard PNG compression (Google’s figure), less on top of oxipng."
        case .pngquant: return "Turns PNG screenshots and graphics into 256-colour PNGs: often up to 70% smaller (pngquant’s figure)."
        case .mozjpeg: return "Tried alongside Apple’s encoder when you keep “Same format”; the smaller file wins. Up to 15% smaller at the same quality (Mozilla’s figure)."
        }
    }

    static let lossless: [OptionalTool] = [.qpdf, .gifsicle, .jpegTurbo, .oxipng, .zopfli]

    /// The lossless Compress category this tool works on (nil for the Shrink tools).
    var compressCategory: CompressCategory? {
        switch self {
        case .qpdf: return .pdfs
        case .jpegTurbo: return .jpeg
        case .gifsicle, .oxipng, .zopfli: return .images
        case .pngquant, .mozjpeg: return nil
        }
    }

    var isInstalledNow: Bool {
        switch self {
        case .pngquant: return ShrinkTools.detect().pngquant != nil
        case .mozjpeg: return ShrinkTools.detect().mozjpeg != nil
        default:
            let tools = CompressTools.detect()
            switch self {
            case .qpdf: return tools.qpdf != nil
            case .gifsicle: return tools.gifsicle != nil
            case .jpegTurbo: return tools.jpegtran != nil
            case .oxipng: return tools.oxipng != nil
            case .zopfli: return tools.zopflipng != nil
            default: return false
            }
        }
    }

    static func installCommand(_ tools: [OptionalTool]) -> String {
        "brew install " + tools.map(\.formula).joined(separator: " ")
    }
}

/// Files a scan found that a missing tool would have handled.
struct ToolFind: Sendable, Hashable {
    var count: Int = 0
    var bytes: Int64 = 0
    /// Singular: "PDF", "GIF", "PNG", "JPEG".
    var noun: String

    var countText: String { "\(count.formatted()) \(noun)\(count == 1 ? "" : "s")" }

    var summary: String {
        "\(countText) · \(FileSizeHelper.formatBytes(bytes)) found"
    }
}

// MARK: - Installing

/// Runs `brew install` for the tools the user picked, one formula at a time so one failure doesn't sink the rest.
@MainActor
final class ToolInstaller: ObservableObject {
    static let shared = ToolInstaller()

    enum ToolState: Equatable {
        case waiting, installing, installed, failed
    }

    @Published private(set) var states: [OptionalTool: ToolState] = [:]
    @Published private(set) var isRunning = false
    @Published private(set) var current: OptionalTool?
    @Published private(set) var output: [String] = []
    @Published private(set) var lastError: String?
    /// Bumped after every run, so screens can re-detect tools and rescan.
    @Published private(set) var finishedRuns = 0
    @Published private(set) var wasCancelled = false
    /// Tools the most recent run actually installed, so screens rescan only when it matters to them.
    @Published private(set) var lastRunInstalled: Set<OptionalTool> = []

    private var process: Process?
    private var cancelRequested = false

    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var hasResults: Bool { !states.isEmpty }
    var failedTools: [OptionalTool] { OptionalTool.allCases.filter { states[$0] == .failed } }
    var installedTools: [OptionalTool] { OptionalTool.allCases.filter { states[$0] == .installed } }
    func state(_ tool: OptionalTool) -> ToolState? { states[tool] }

    /// Clears the last run's per-tool results (the card closes or the user dismisses it).
    func reset() {
        guard !isRunning else { return }
        states = [:]
        output = []
        lastError = nil
        wasCancelled = false
    }

    func install(_ tools: [OptionalTool]) {
        guard !isRunning, let brew = Self.brewPath else { return }
        let queue = tools.filter { states[$0] != .installed }
        guard !queue.isEmpty else { return }
        isRunning = true
        cancelRequested = false
        wasCancelled = false
        lastError = nil
        output = []
        for tool in queue { states[tool] = .waiting }
        Task {
            var first = true
            var installedNow: Set<OptionalTool> = []
            for tool in queue {
                if cancelRequested { states[tool] = nil; continue }
                current = tool
                states[tool] = .installing
                let (code, tail) = await run(brew: brew, formula: tool.formula, autoUpdate: first)
                first = false
                if cancelRequested {
                    let ok = tool.isInstalledNow
                    states[tool] = ok ? .installed : nil
                    if ok { installedNow.insert(tool) }
                    continue
                }
                if code == 0 || tool.isInstalledNow {
                    states[tool] = .installed
                    installedNow.insert(tool)
                } else {
                    states[tool] = .failed
                    lastError = tail.isEmpty ? "Homebrew stopped with exit code \(code)." : tail
                }
            }
            current = nil
            isRunning = false
            wasCancelled = cancelRequested
            process = nil
            lastRunInstalled = installedNow
            finishedRuns += 1
        }
    }

    func cancel() {
        guard isRunning else { return }
        cancelRequested = true
        process?.interrupt()
        let running = process
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if running?.isRunning == true { running?.terminate() }
        }
    }

    /// Runs one `brew install`, streaming output into `output`. Returns the exit code and the last error lines.
    private func run(brew: String, formula: String, autoUpdate: Bool) async -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["install", formula]
        process.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        let brewBin = (brew as NSString).deletingLastPathComponent
        env["PATH"] = ([brewBin, "/usr/bin", "/bin", "/usr/sbin", "/sbin"] + (env["PATH"] ?? "").split(separator: ":").map(String.init))
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: ":")
        env["NONINTERACTIVE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_COLOR"] = "1"
        // Homebrew sends its own usage analytics unless told not to; Furl shouldn't trigger that.
        env["HOMEBREW_NO_ANALYTICS"] = "1"
        // Homebrew refreshes its formula list once; later installs in the same run don't need to again.
        if !autoUpdate { env["HOMEBREW_NO_AUTO_UPDATE"] = "1" }
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        output.append("$ brew install \(formula)")

        let collected = LineCollector()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            // Lossy decode: a chunk can split a multibyte character, which would make a strict decode drop it.
            let text = String(decoding: data, as: UTF8.self)
            let lines = collected.add(text)
            guard !lines.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.output.append(contentsOf: lines)
                if self.output.count > 400 { self.output.removeFirst(self.output.count - 400) }
            }
        }

        let code: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { p in continuation.resume(returning: p.terminationStatus) }
            do {
                try process.run()
                self.process = process
            } catch {
                process.terminationHandler = nil
                collected.appendLine("Couldn't start Homebrew: \(error.localizedDescription)")
                continuation.resume(returning: -1)
            }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        // Homebrew's final "Error:" lines can still be in the pipe after it exits; read them before summarising.
        // Non-blocking: a background child of brew can keep the pipe open, and a blocking read would hang the UI.
        let leftover = Self.drainAvailable(pipe.fileHandleForReading.fileDescriptor)
        if !leftover.isEmpty {
            let lines = collected.add(String(decoding: leftover, as: UTF8.self))
            if !lines.isEmpty { output.append(contentsOf: lines) }
        }
        let rest = collected.flush()
        if !rest.isEmpty { output.append(contentsOf: rest) }
        return (code, collected.errorTail())
    }

    /// Reads whatever is already buffered in the pipe without waiting for EOF.
    private static func drainAvailable(_ fd: Int32) -> Data {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return Data() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count < 1_000_000 {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 { data.append(buffer, count: n) } else if n < 0, errno == EINTR { continue } else { break }
        }
        return data
    }
}

/// Splits streamed output into lines across chunk boundaries; thread-safe.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var partial = ""
    private var all: [String] = []

    func add(_ text: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        partial += text.replacingOccurrences(of: "\r", with: "\n")
        var lines = partial.components(separatedBy: "\n")
        partial = lines.removeLast()
        lines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        all.append(contentsOf: lines)
        return lines
    }

    func appendLine(_ line: String) {
        lock.lock(); all.append(line); lock.unlock()
    }

    func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let rest = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        partial = ""
        guard !rest.isEmpty else { return [] }
        all.append(rest)
        return [rest]
    }

    /// Homebrew's own error lines if it printed any, else the last few lines, verbatim.
    func errorTail() -> String {
        lock.lock(); defer { lock.unlock() }
        if let start = all.lastIndex(where: { $0.hasPrefix("Error:") }) {
            return all[start...].prefix(6).joined(separator: "\n")
        }
        return all.suffix(4).joined(separator: "\n")
    }
}
