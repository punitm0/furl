import SwiftUI

/// Settings › General › Appearance › Theme (ThemeSettings board, canvas v56).
/// Five radio cards (88 × 56, so all five fit the 560 pt window); a click applies the theme everywhere at once.
struct ThemePickerRow: View {
    @AppStorage(FurlPalette.defaultsKey) private var paletteRaw = FurlPalette.mint.rawValue

    private var selected: FurlPalette { FurlPalette(rawValue: paletteRaw) ?? .mint }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Theme")
            HStack(alignment: .top, spacing: 10) {
                ForEach(FurlPalette.allCases) { palette in
                    ThemeCard(palette: palette, isSelected: palette == selected) {
                        paletteRaw = palette.rawValue
                    }
                    if palette != FurlPalette.allCases.last { Spacer(minLength: 0) }
                }
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Theme")
            .onMoveCommand { direction in
                let all = FurlPalette.allCases
                guard let index = all.firstIndex(of: selected) else { return }
                switch direction {
                case .left where index > 0: paletteRaw = all[index - 1].rawValue
                case .right where index < all.count - 1: paletteRaw = all[index + 1].rawValue
                default: break
                }
            }
            Text("Changes right away. Each theme has a light and a dark look; Furl follows your Mac's Light or Dark setting. The curl in the Furl icon takes the theme’s colour.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

private struct ThemeCard: View {
    let palette: FurlPalette
    let isSelected: Bool
    let select: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    HStack(spacing: 0) {
                        half(dark: false)
                        half(dark: true)
                    }
                    .frame(width: 88, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(restStroke, lineWidth: 1)
                            .opacity(isSelected ? 0 : 1)
                    }
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 9 + 1.25, style: .continuous)
                                .stroke(ThemeToken.sweep.color(in: palette, dark: colorScheme == .dark), lineWidth: 2.5)
                                .padding(-1.25)
                        }
                    }
                    if isSelected { badge.offset(x: 6, y: -6) }
                }
                Text(palette.displayName)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Text(palette == .mint ? "Default" : " ")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(height: 12)
                    .padding(.top, -4)
            }
            .frame(width: 88)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(palette.displayName) theme")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// Rest: 1 pt black at 12% (white at 15% in dark). Hover: 30%.
    private var restStroke: Color {
        colorScheme == .dark
            ? Color.white.opacity(isHovered ? 0.3 : 0.15)
            : Color.black.opacity(isHovered ? 0.3 : 0.12)
    }

    private var badge: some View {
        ZStack {
            Circle().fill(ThemeToken.sweep.color(in: palette, dark: colorScheme == .dark))
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.white)
        }
        .frame(width: 18, height: 18)
        .overlay(Circle().stroke(colorScheme == .dark ? Color(nsColor: NSColor(hex: 0x2B2B2B)) : .white, lineWidth: 2))
    }

    /// One half of the card: the theme's ground, a hero with the Curl f glyph and an accent bar,
    /// then a sweep button and a plain button.
    private func half(dark: Bool) -> some View {
        func c(_ token: ThemeToken) -> Color { token.color(in: palette, dark: dark) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                MiniMark(letter: c(.onPine), curl: c(.mint)).frame(width: 12, height: 12)
                Capsule().fill(c(.mint)).frame(width: 16, height: 5)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .frame(height: 22)
            .background(c(.pine), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 3).fill(c(.sweep)).frame(width: 20, height: 8)
                RoundedRectangle(cornerRadius: 3).fill(c(.surface))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(c(.controlBorder), lineWidth: 1))
                    .frame(width: 10, height: 8)
            }
            Spacer(minLength: 0)
        }
        .padding(5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(c(.ground))
    }
}

/// The Curl f glyph at preview size: the f in the theme's onPine, the curl in its accent
/// (ThemeSettings board: small-size shape, stroke 9 of 64).
private struct MiniMark: View {
    let letter: Color
    let curl: Color

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let scale = side / 64
            let shape = SweepMarkRenderer.paths(glyph: true, scale: scale, origin: .zero)
            let stroke = StrokeStyle(lineWidth: 9 * scale, lineCap: .round, lineJoin: .round)
            context.stroke(shape.f, with: .color(letter), style: stroke)
            context.stroke(shape.bar, with: .color(letter), style: stroke)
            context.stroke(shape.curl, with: .color(curl), style: stroke)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
