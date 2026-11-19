import AppKit
import SwiftUI

// MARK: - Clean Slate design tokens

/// Colour, type, spacing and radius tokens for the "Clean Slate" design.
/// Every colour adapts to Dark Mode through a dynamic `NSColor`.
enum Theme {
    // MARK: Brand palette

    /// Pine — hero surfaces (dark mode: quieter pine with a 1px inset `pineBorder`) (Overview panel, app icon tile).
    static let pine = Color(themed: .pine)
    /// Slightly lighter pine used for rings/tracks on top of `pine`.
    static let pineTrack = Color(themed: .pineTrack)
    /// Border on pine surfaces (secondary buttons).
    static let pineBorder = Color(themed: .pineBorder)
    /// Muted text on pine.
    static let pineMuted = Color(themed: .pineMuted)
    /// Primary text on pine.
    static let onPine = Color(themed: .onPine)

    /// Sweep — primary actions.
    static let sweep = Color(themed: .sweep)
    /// Label on sweep-filled buttons (white in light; dark text in dark mode for contrast).
    static let onSweep = Color(themed: .onSweep)
    /// Label on danger-filled buttons (white on #F27A5C would fail contrast in dark mode).
    static let onDanger = Color(themed: .onDanger)
    /// Label on warning-filled buttons (lossy actions).
    static let onWarning = Color(themed: .onWarning)
    /// 1px inset stroke on the hero, shown only in dark mode (the theme's dark pineBorder).
    static let heroStroke = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(hex: ThemeToken.pineBorder.value(in: .current).dark) : .clear
    })
    /// Darker sweep for text on a mint tint.
    static let sweepDeep = Color(themed: .sweepDeep)
    /// Mint — space freed, used on dark surfaces.
    static let mint = Color(themed: .mint)
    /// Label on mint-filled hero buttons: pine #0B3D30 in both modes (MainDark, HeroScanningDark).
    static let onMint = Color(themed: .onMint)
    /// Mint tint background for pills and badges.
    static let mintTint = Color(themed: .mintTint)
    /// Memory — RAM.
    static let memory = Color(themed: .memory)
    static let memoryTint = Color(themed: .memoryTint)
    static let memoryOnPine = Color(themed: .memoryOnPine)

    // MARK: Neutrals

    /// Ink — primary text.
    static let ink = Color(themed: .ink)
    /// Secondary text.
    static let inkSecondary = Color(themed: .inkSecondary)
    /// Tertiary text / body copy on light cards.
    static let inkTertiary = Color(themed: .inkTertiary)
    /// Window ground.
    static let ground = Color(themed: .ground)
    /// Sidebar ground.
    static let sidebar = Color(themed: .sidebar)
    /// Card / raised surface.
    static let surface = Color(themed: .surface)
    /// Subtle header row inside a card.
    static let surfaceSubtle = Color(themed: .surfaceSubtle)
    /// Card borders.
    static let border = Color(themed: .border)
    /// Hairlines between rows.
    static let hairline = Color(themed: .hairline)
    /// Control borders (buttons, search field).
    static let controlBorder = Color(themed: .controlBorder)
    /// "In use" segment on light surfaces.
    static let usedBar = Color(themed: .usedBar)
    /// "Can free" segment on light surfaces.
    static let freeableBar = Color(themed: .freeableBar)

    // MARK: Status

    static let warning = Color(themed: .warning)
    static let warningTint = Color(themed: .warningTint)
    static let danger = Color(themed: .danger)
    static let dangerTint = Color(themed: .dangerTint)
    static let violet = Color(themed: .violet)
    static let violetTint = Color(themed: .violetTint)

    /// Category accents (tile icon colour, tile tint).
    struct Accent {
        let fg: Color
        let bg: Color
    }

    static let accentOrange = Accent(fg: warning, bg: warningTint)
    static let accentViolet = Accent(fg: violet, bg: violetTint)
    static let accentBlue = Accent(fg: memory, bg: memoryTint)
    static let accentPink = Accent(fg: Color(themed: .accentPinkFg), bg: Color(themed: .accentPinkBg))
    static let accentTeal = Accent(fg: Color(themed: .accentTealFg), bg: Color(themed: .accentTealBg))
    static let accentGreen = Accent(fg: sweep, bg: mintTint)
    static let accentGray = Accent(fg: inkSecondary, bg: Color(themed: .accentGrayBg))

    // Named on the FurlTokens board. lime is for bars and dots only (3.7:1 on white, too low for text).
    static let lime = Color(themed: .lime)
    static let indigo = Color(themed: .indigo)
    static let chartHighlight = Color(themed: .chartHighlight)
    static let toastBackground = Color(themed: .toastBackground)
    static let toastBorder = Color(themed: .toastBorder)
    static let onToast = Color(themed: .onToast)
    static let toastUndoFill = Color(themed: .toastUndoFill)
    /// Support sheet (Support board): selected amount chip (segmentSelected is unused since One time / Monthly was dropped).
    /// Drawn on the Support boards but not listed on the token boards.
    static let segmentSelected = Color(themed: .segmentSelected)
    static let amountSelected = Color(themed: .amountSelected)
    /// Details box inside the multi-problem error bar (SystemSurfaces: white 60% / black 25%).
    static let errorDetailFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0, alpha: 0.25) : NSColor(white: 1, alpha: 0.6)
    })
    /// Shadow under the selected sidebar row (light: ink at 8%, dark: black at 40%).
    static let sidebarSelectionShadow = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0, alpha: 0.4) : NSColor(hex: ThemeToken.ink.value(in: .current).light, alpha: 0.08)
    })

    // Drawn on the Snapshots boards (not on the token boards).
    /// "It grew 4.2 GB" / "+3.1 GB net" text.
    static let growth = Color(themed: .growth)
    /// Home-folder size line in the Snapshots chart.
    static let growthLine = Color(themed: .growthLine)
    /// Downloads category slice.
    static let downloads = Color(themed: .downloads)

    /// The "Safe" badge colour and its tint. Green in every theme, even Indigo Night.
    static let safe = Color(themed: .safe)
    static let safeTint = Color(themed: .safeTint)

    /// Status green ("On", success states). Same values as sweep today, named separately so
    /// it survives a palette change (design round 2). Don't use the Downloads chart green.
    static let success = Color(light: 0x0B7A5E, dark: 0x3FBF93)

    /// Free segment of the hero ring and its legend, on pine (FurlTokens).
    static let storageFreeOnPine = Color(themed: .storageFreeOnPine)
    /// System segment of the storage breakdown.
    static let storageSystem = Color(themed: .storageSystem)
    /// Other segment of the storage breakdown.
    static let storageOther = Color(themed: .storageOther)
    /// Line between the sidebar and the detail column.
    static let sidebarBorder = Color(themed: .sidebarBorder)

    /// Palette for stacked category bars (Caches & Junk).
    /// No orange or amber: orange only ever means caution.
    static let chartPalette: [Color] = [
        lime,
        Color(light: 0x7048E8, dark: 0x9D85F5),
        Color(light: 0x1C7ED6, dark: 0x5AA9F0),
        Color(light: 0x0CA678, dark: 0x38D9A9),
        Color(light: 0xD6336C, dark: 0xF06595),
        indigo,
        Color(light: 0x868E96, dark: 0xADB5BD),
        Color(light: 0x1098AD, dark: 0x3BC9DB),
        Color(light: 0x9C36B5, dark: 0xDA77F2), // [8] grape: Browser Caches
        Color(light: 0xA1284A, dark: 0xF28BA8), // [9] berry: Mail Attachments
        Color(light: 0x52617A, dark: 0xA3B1C6), // [10] slate: iOS Simulators
        Color(light: 0x85603F, dark: 0xD3A27F)  // [11] umber: Local AI Models
    ]

    // MARK: Spacing & radius

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 22
        static let xxl: CGFloat = 28
        /// Horizontal page gutter.
        static let page: CGFloat = 28
    }

    enum Radius {
        static let control: CGFloat = 8
        static let pill: CGFloat = 10
        static let row: CGFloat = 8
        static let card: CGFloat = 14
        static let hero: CGFloat = 16
        static let button: CGFloat = 9
    }

    // MARK: Type

    /// Display numerals (stands in for Space Grotesk).
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static let pageTitle = Font.system(size: 20, weight: .bold)
    static let pageSubtitle = Font.system(size: 12)
    static let sectionLabel = Font.system(size: 11, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyStrong = Font.system(size: 13, weight: .semibold)
    static let caption = Font.system(size: 12)
    static let micro = Font.system(size: 11)
}

extension Color {
    /// Creates a colour that switches between two hex values for light and dark appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - Logo

/// The Furl mark, "Curl f": an f whose stem rises and rolls into a curl, on a graphite tile
/// (Brand board, FurlLogoCurlF board). The tile is graphite in every theme; the curl takes the
/// theme's accent (`Theme.mint`). Drawn in a 64×64 design space.
struct SweepMark: View {
    enum Style {
        /// Graphite rounded tile, light f and accent curl (sidebar logo, About, first run).
        case tile
        /// No tile: light f and accent curl, for use on a hero (pine token) surface.
        case onPine
        /// Single colour (menu bar style), uses `templateColor`.
        case template
    }

    var style: Style = .tile
    /// The bolder small-size glyph (Brand board: menu bar and sizes under 32 pt).
    var simplified: Bool = false

    var body: some View {
        Canvas { context, size in
            SweepMarkRenderer.draw(in: &context, size: size, style: style, simplified: simplified)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Furl")
    }
}

/// Shared drawing code so every in-app mark and the Dock icon render the same Curl f.
enum SweepMarkRenderer {
    /// Graphite tile: the same in every theme and in light and dark.
    static let tileHex: UInt32 = 0x1C1C1C
    /// The light f on the tile.
    static let letterHex: UInt32 = 0xF2F2EE

    /// The f (stem, shoulder) and the curl as separate paths, plus the cross bar, in 64-unit space.
    /// `glyph` is the bolder small-size shape (stroke 8 instead of 6).
    static func paths(glyph: Bool, scale: CGFloat, origin: CGPoint) -> (f: Path, curl: Path, bar: Path, lineWidth: CGFloat) {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * scale, y: origin.y + y * scale) }
        // In SwiftUI's y-down space, clockwise: false draws visually clockwise, like the SVG's sweep flag 1.
        var f = Path(), curl = Path(), bar = Path()
        if glyph {
            // M24 56 V26 a14 14 0 0 1 14 -14 | a9 9 0 0 1 0 18 a4 4 0 0 1 0 -8 | M12 36 H34
            f.move(to: pt(24, 56)); f.addLine(to: pt(24, 26))
            f.addArc(center: pt(38, 26), radius: 14 * scale, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            curl.move(to: pt(38, 12))
            curl.addArc(center: pt(38, 21), radius: 9 * scale, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            curl.addArc(center: pt(38, 26), radius: 4 * scale, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
            bar.move(to: pt(12, 36)); bar.addLine(to: pt(34, 36))
            return (f, curl, bar, 8 * scale)
        }
        // M26 52 V26 a12 12 0 0 1 12 -12 | M38 14 a7 7 0 0 1 0 14 a3.5 3.5 0 0 1 0 -7 | M17 34 H35
        f.move(to: pt(26, 52)); f.addLine(to: pt(26, 26))
        f.addArc(center: pt(38, 26), radius: 12 * scale, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        curl.move(to: pt(38, 14))
        curl.addArc(center: pt(38, 21), radius: 7 * scale, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        curl.addArc(center: pt(38, 24.5), radius: 3.5 * scale, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
        bar.move(to: pt(17, 34)); bar.addLine(to: pt(35, 34))
        return (f, curl, bar, 6 * scale)
    }

    static func draw(
        in context: inout GraphicsContext,
        size: CGSize,
        style: SweepMark.Style,
        simplified: Bool,
        templateColor: Color = Theme.ink,
        curlColor: Color = Theme.mint
    ) {
        let side = min(size.width, size.height)
        let scale = side / 64
        let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)

        let letter: Color
        let accent: Color
        switch style {
        case .tile:
            let tile = Path(roundedRect: CGRect(origin: origin, size: CGSize(width: side, height: side)),
                            cornerRadius: 14.5 * scale, style: .continuous)
            context.fill(tile, with: .color(Color(nsColor: NSColor(hex: tileHex))))
            letter = Color(nsColor: NSColor(hex: letterHex))
            accent = curlColor
        case .onPine:
            letter = Theme.onPine
            accent = curlColor
        case .template:
            letter = templateColor
            accent = templateColor
        }

        let shape = paths(glyph: simplified || style == .template, scale: scale, origin: origin)
        let stroke = StrokeStyle(lineWidth: shape.lineWidth, lineCap: .round, lineJoin: .round)
        context.stroke(shape.f, with: .color(letter), style: stroke)
        context.stroke(shape.bar, with: .color(letter), style: stroke)
        context.stroke(shape.curl, with: .color(accent), style: stroke)
    }

    /// The mark as an AppKit image (menu bar glyph, Dock icon). `curlHex` nil draws a single-colour
    /// template glyph in black, for `isTemplate` images.
    static func image(points: CGFloat, tile: Bool, glyph: Bool, curlHex: UInt32?, inset: CGFloat = 0) -> NSImage {
        let image = NSImage(size: NSSize(width: points, height: points), flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let side = rect.width - inset * 2
            let scale = side / 64
            let origin = CGPoint(x: inset, y: inset)
            if tile {
                let tilePath = Path(roundedRect: CGRect(origin: origin, size: CGSize(width: side, height: side)),
                                    cornerRadius: 14.5 * scale, style: .continuous)
                cg.addPath(tilePath.cgPath)
                cg.setFillColor(NSColor(hex: tileHex).cgColor)
                cg.fillPath()
            }
            let shape = paths(glyph: glyph, scale: scale, origin: origin)
            cg.setLineWidth(shape.lineWidth)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            let letter = curlHex == nil ? NSColor.black : NSColor(hex: letterHex)
            for (path, color) in [(shape.f, letter), (shape.bar, letter), (shape.curl, curlHex.map { NSColor(hex: $0) } ?? .black)] {
                cg.addPath(path.cgPath)
                cg.setStrokeColor(color.cgColor)
                cg.strokePath()
            }
            return true
        }
        image.isTemplate = curlHex == nil
        image.accessibilityDescription = "Furl"
        return image
    }
}

/// The Dock icon follows the theme's curl colour while Furl runs (ThemeSettings board). Themes
/// whose curl is mint use the bundled icon, which is also what Finder shows.
@MainActor
enum DockIcon {
    private static var appliedCurl: UInt32?
    private static var observer: NSObjectProtocol?

    static func start() {
        update()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { update() }
        }
    }

    static func update() {
        let curl = ThemeToken.mint.value(in: .current).light
        guard curl != appliedCurl else { return }
        appliedCurl = curl
        if curl == ThemeToken.mint.value(in: .mint).light {
            NSApp.applicationIconImage = nil
            return
        }
        // Same grid as scripts/make_icon.swift: the tile fills 80% of the canvas.
        NSApp.applicationIconImage = SweepMarkRenderer.image(points: 512, tile: true, glyph: false, curlHex: curl, inset: 51.2)
    }
}

/// Logo + wordmark lockup.
struct SweepWordmark: View {
    var markSize: CGFloat = 28
    var fontSize: CGFloat = 18

    var body: some View {
        HStack(spacing: 10) {
            SweepMark(style: .tile)
                .frame(width: markSize, height: markSize)
            Text("Furl")
                .font(Theme.display(fontSize))
                .tracking(-0.1)
                .foregroundStyle(Theme.ink)
        }
    }
}

// MARK: - Privacy badge

/// "Private by default · Works offline · Your files never leave your Mac" pill.
struct PrivacyBadge: View {
    var compact: Bool = false

    private var label: String {
        compact ? "Private · Offline" : "Private by default · Works offline · Your files never leave your Mac"
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 12, weight: .semibold))
            Text(label)
                .lineLimit(1)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Theme.sweepDeep)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Theme.mintTint, in: Capsule())
        .help("Furl works entirely on this Mac, with no account. Your files, their names and what's inside them never leave your Mac.")
        .accessibilityElement(children: .combine)
    }
}
