import AppKit
import SwiftUI

// Generated from the FurlPalettes board (design canvas v56): every themed Theme colour,
// light and dark, for each of the five palettes (Mint, Rosewood, Harbour, Sailcloth, Indigo Night). Mint (graphite + mint, the icon's colours) is the default.

enum FurlPalette: String, CaseIterable, Identifiable, Sendable {
    case mint, rosewood, harbour, sailcloth, indigoNight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mint: return "Mint"
        case .rosewood: return "Rosewood"
        case .harbour: return "Harbour"
        case .sailcloth: return "Sailcloth"
        case .indigoNight: return "Indigo Night"
        }
    }

    static let defaultsKey = "appearance.palette"

    /// The palette colours resolve against. Read from any thread (NSColor providers run off-main).
    static var current: FurlPalette {
        FurlPalette(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .mint
    }
}

enum ThemeToken: Sendable {
    case safe, safeTint, pine, pineTrack, pineBorder, pineMuted, onPine, sweep, onSweep, onDanger, onWarning, sweepDeep, mint, onMint, mintTint, memory, memoryTint, memoryOnPine, ink, inkSecondary, inkTertiary, ground, sidebar, surface, surfaceSubtle, border, hairline, controlBorder, usedBar, freeableBar, warning, warningTint, danger, dangerTint, violet, violetTint, lime, indigo, chartHighlight, toastBackground, toastBorder, onToast, toastUndoFill, segmentSelected, amountSelected, growth, growthLine, downloads, storageFreeOnPine, storageSystem, storageOther, sidebarBorder, accentPinkFg, accentPinkBg, accentTealFg, accentTealBg, accentGrayBg

    /// (light, dark) hex for each palette, in FurlPalette.allCases order.
    var values: [(UInt32, UInt32)] {
        switch self {
        // Every theme keeps a green "Safe" (ThemeSettings board); Indigo Night borrows Pine's.
        case .safe: return [(0x0B7A5E, 0x3FBF93), (0x0B7A5E, 0x3FBF93), (0x0E7A6B, 0x3CC4A8), (0x3C6E2F, 0x9FD27A), (0x0B7A5E, 0x3FBF93)]
        case .safeTint: return [(0xDDF3EA, 0x1A2E28), (0xDDF3EA, 0x1A2E28), (0xDDF2EE, 0x16302B), (0xE7F1DA, 0x24331F), (0xDDF3EA, 0x1A2E28)]
        case .pine: return [(0x1C1C1C, 0x232322), (0x3A1C2C, 0x2E1623), (0x12304A, 0x0F2638), (0x233524, 0x1B281C), (0x1C2152, 0x151938)]
        case .pineTrack: return [(0x333331, 0x353533), (0x54303F, 0x45273A), (0x22445F, 0x1E3A50), (0x344A35, 0x2C3F2D), (0x2E3470, 0x262B5A)]
        case .pineBorder: return [(0x4A4A47, 0x464643), (0x7F4E63, 0x5C3A4B), (0x3D6280, 0x2E4A62), (0x557055, 0x3D543E), (0x4A5196, 0x3A4078)]
        case .pineMuted: return [(0xB5B5AD, 0xA6A69E), (0xD8B9C6, 0xC7A8B6), (0xA8BFD2, 0x9AB1C4), (0xBFCDB8, 0xAFBEA8), (0xB6BCE8, 0xA6ACD8)]
        case .onPine: return [(0xF2F2EE, 0xF2F2EE), (0xFBEFF4, 0xF5E8EE), (0xEAF3FA, 0xE6EEF5), (0xF3F1E8, 0xEEEBE0), (0xEEF0FF, 0xE8EAFB)]
        case .sweep: return [(0x0B7A5E, 0x3FBF93), (0xA3305F, 0xF08DB4), (0x0E7A6B, 0x3CC4A8), (0x3C6E2F, 0x9FD27A), (0x4C56D1, 0x8F98F5)]
        case .onSweep: return [(0xFFFFFF, 0x0E1F19), (0xFFFFFF, 0x2B0F1C), (0xFFFFFF, 0x0B1F1B), (0xFFFFFF, 0x132010), (0xFFFFFF, 0x12153A)]
        case .onDanger: return [(0xFFFFFF, 0x2B120C), (0xFFFFFF, 0x2B120C), (0xFFFFFF, 0x2B120C), (0xFFFFFF, 0x2B120C), (0xFFFFFF, 0x2B120C)]
        case .onWarning: return [(0xFFFFFF, 0x2B1A0C), (0xFFFFFF, 0x2B1A0C), (0xFFFFFF, 0x2B1A0C), (0xFFFFFF, 0x2B1A0C), (0xFFFFFF, 0x2B1A0C)]
        case .sweepDeep: return [(0x075A45, 0x7FE0BC), (0x7E2148, 0xF7B5CF), (0x095A4F, 0x7FE3CC), (0x2C5422, 0xC2E5A3), (0x343CA8, 0xB4BAFA)]
        case .mint: return [(0x5FE3B0, 0x5FE3B0), (0xF7A1C4, 0xF7A1C4), (0x2DD4BF, 0x2DD4BF), (0xB5E67C, 0xB5E67C), (0xB197FC, 0xB197FC)]
        case .onMint: return [(0x1C1C1C, 0x1C1C1C), (0x3A1C2C, 0x3A1C2C), (0x12304A, 0x12304A), (0x233524, 0x233524), (0x1C2152, 0x1C2152)]
        case .mintTint: return [(0xDDF3EA, 0x1A2E28), (0xFBE5EE, 0x3A2230), (0xDDF2EE, 0x16302B), (0xE7F1DA, 0x24331F), (0xE6E8FD, 0x22264A)]
        case .memory: return [(0x1A5FB4, 0x6EA8F0), (0x1A5FB4, 0x6EA8F0), (0x1A5FB4, 0x6EA8F0), (0x1A5FB4, 0x6EA8F0), (0x0B7285, 0x66D9E8)]
        case .memoryTint: return [(0xE1ECFA, 0x1C2633), (0xE1ECFA, 0x1C2633), (0xE1ECFA, 0x1C2633), (0xE1ECFA, 0x1C2633), (0xE0F4F7, 0x16303A)]
        case .memoryOnPine: return [(0x9CC8FF, 0x9CC8FF), (0x9CC8FF, 0x9CC8FF), (0x9CC8FF, 0x9CC8FF), (0x9CC8FF, 0x9CC8FF), (0x99E9F2, 0x99E9F2)]
        case .ink: return [(0x1A1A1A, 0xEDEDEA), (0x22171C, 0xEFEAEC), (0x141C24, 0xECEFF2), (0x1F1D19, 0xEEEBE4), (0x16182A, 0xECEDF3)]
        case .inkSecondary: return [(0x63635D, 0xA6A69E), (0x6A5A61, 0xAFA3A8), (0x586573, 0xA0A9B2), (0x6A665C, 0xA9A498), (0x5C6075, 0xA3A6B8)]
        case .inkTertiary: return [(0x43433F, 0xC9C9C3), (0x4A3C42, 0xCFC5C9), (0x3A4652, 0xC3CAD1), (0x45413A, 0xCAC5B9), (0x3D4055, 0xC6C8D6)]
        case .ground: return [(0xF5F5F2, 0x141413), (0xF8F5F6, 0x171214), (0xF5F7F9, 0x131619), (0xF7F5F0, 0x161512), (0xF6F6FA, 0x131420)]
        case .sidebar: return [(0xECECE8, 0x1B1B1A), (0xF0EBED, 0x1E181B), (0xEBEFF3, 0x1A1E22), (0xEFECE4, 0x1D1B18), (0xECEDF4, 0x1A1B28)]
        case .surface: return [(0xFFFFFF, 0x20201F), (0xFFFFFF, 0x231C1F), (0xFFFFFF, 0x1E2226), (0xFFFFFF, 0x22201C), (0xFFFFFF, 0x1E1F2E)]
        case .surfaceSubtle: return [(0xFAFAF8, 0x262625), (0xFBF9FA, 0x292125), (0xFAFBFC, 0x23282D), (0xFBFAF6, 0x282622), (0xFAFAFD, 0x242536)]
        case .border: return [(0xE3E3DE, 0x343432), (0xE8E0E3, 0x3A3135), (0xE1E6EB, 0x31373D), (0xE6E1D6, 0x38342E), (0xE2E3EC, 0x333548)]
        case .hairline: return [(0xEEEEEA, 0x2B2B29), (0xF1ECEE, 0x302829), (0xEDF1F4, 0x292E33), (0xF0ECE3, 0x2F2C27), (0xEEEFF5, 0x2A2C3D)]
        case .controlBorder: return [(0xD0D0CA, 0x464643), (0xD6CBD0, 0x4C4146), (0xCBD3DB, 0x424A52), (0xD3CDBF, 0x4A453D), (0xCDCFDD, 0x45475D)]
        case .usedBar: return [(0x33332F, 0xBDBDB6), (0x3A2E33, 0xC3B9BD), (0x2D3A47, 0xB7C0C9), (0x3A362F, 0xC4BFB3), (0x2E3045, 0xBABCCB)]
        case .freeableBar: return [(0x12A67F, 0x3CCB9C), (0x12A67F, 0x3CCB9C), (0x14A68C, 0x3CCBAE), (0x5E9A3A, 0x9FD27A), (0x12A67F, 0x3CCB9C)]
        case .warning: return [(0xB54708, 0xF2A065), (0xB54708, 0xF2A065), (0xB54708, 0xF2A065), (0xB54708, 0xF2A065), (0xB54708, 0xF2A065)]
        case .warningTint: return [(0xFDEBDD, 0x3A2A1E), (0xFDEBDD, 0x3A2A1E), (0xFDEBDD, 0x3A2A1E), (0xFDEBDD, 0x3A2A1E), (0xFDEBDD, 0x3A2A1E)]
        case .danger: return [(0xC4320A, 0xF27A5C), (0xC4320A, 0xF27A5C), (0xC4320A, 0xF27A5C), (0xC4320A, 0xF27A5C), (0xC4320A, 0xF27A5C)]
        case .dangerTint: return [(0xFDE7E1, 0x3B2320), (0xFDE7E1, 0x3B2320), (0xFDE7E1, 0x3B2320), (0xFDE7E1, 0x3B2320), (0xFDE7E1, 0x3B2320)]
        case .violet: return [(0x5B3CC4, 0xA993F5), (0x5B3CC4, 0xA993F5), (0x5B3CC4, 0xA993F5), (0x5B3CC4, 0xA993F5), (0xA61E8C, 0xE87BD3)]
        case .violetTint: return [(0xECE6FD, 0x2A2738), (0xECE6FD, 0x2A2738), (0xECE6FD, 0x2A2738), (0xECE6FD, 0x2A2738), (0xFBE6F6, 0x3A2235)]
        case .lime: return [(0x5C940D, 0xA9E34B), (0x5C940D, 0xA9E34B), (0x5C940D, 0xA9E34B), (0x0B7285, 0x66D9E8), (0x5C940D, 0xA9E34B)]
        case .indigo: return [(0x4263EB, 0x91A7FF), (0x4263EB, 0x91A7FF), (0x4263EB, 0x91A7FF), (0x4263EB, 0x91A7FF), (0x4263EB, 0x91A7FF)]
        case .chartHighlight: return [(0x1C1C1C, 0x7FE0BC), (0x3A1C2C, 0xF7B5CF), (0x12304A, 0x7FE3CC), (0x233524, 0xC2E5A3), (0x1C2152, 0xB4BAFA)]
        case .toastBackground: return [(0x1A1A1A, 0x30302E), (0x22171C, 0x342A2E), (0x141C24, 0x2D3339), (0x1F1D19, 0x36332D), (0x16182A, 0x2F3145)]
        case .toastBorder: return [(0x1A1A1A, 0x464643), (0x22171C, 0x4C4146), (0x141C24, 0x434B53), (0x1F1D19, 0x4A453D), (0x16182A, 0x45475D)]
        case .onToast: return [(0xFFFFFF, 0xEDEDEA), (0xFFFFFF, 0xEFEAEC), (0xFFFFFF, 0xECEFED), (0xFFFFFF, 0xECEFED), (0xFFFFFF, 0xECEFED)]
        case .toastUndoFill: return [(0x33332F, 0x464643), (0x3A2E33, 0x4C4146), (0x2D3A47, 0x434B53), (0x3A362F, 0x4A453D), (0x2E3045, 0x45475D)]
        case .segmentSelected: return [(0xFFFFFF, 0x464643), (0xFFFFFF, 0x4C4146), (0xFFFFFF, 0x424846), (0xFFFFFF, 0x424846), (0xFFFFFF, 0x424846)]
        case .amountSelected: return [(0xE6F6EF, 0x1A2E28), (0xFBE8F0, 0x3A2230), (0xE4F5F1, 0x16302B), (0xEDF5E3, 0x24331F), (0xEAECFE, 0x22264A)]
        case .growth: return [(0x8A3B12, 0xF2A065), (0x8A3B12, 0xF2A065), (0x8A3B12, 0xF2A065), (0x8A3B12, 0xF2A065), (0x8A3B12, 0xF2A065)]
        case .growthLine: return [(0xB8742A, 0xF2A065), (0xB8742A, 0xF2A065), (0xB8742A, 0xF2A065), (0xB8742A, 0xF2A065), (0xB8742A, 0xF2A065)]
        case .downloads: return [(0x2B8A3E, 0x69DB7C), (0x2B8A3E, 0x69DB7C), (0x2B8A3E, 0x69DB7C), (0x2B8A3E, 0x69DB7C), (0x2B8A3E, 0x69DB7C)]
        case .storageFreeOnPine: return [(0x5E5E5A, 0x5E5E5A), (0x7A5566, 0x7A5566), (0x4D7391, 0x4D7391), (0x5C7A57, 0x5C7A57), (0x5A61A8, 0x5A61A8)]
        case .storageSystem: return [(0xA3A39C, 0x5E5E59), (0xA89CA1, 0x62575C), (0x98A4B0, 0x56616C), (0xA8A294, 0x625D53), (0x9C9FB2, 0x5A5D72)]
        case .storageOther: return [(0xCFCFC9, 0x40403D), (0xD3C9CD, 0x45393F), (0xC8D0D8, 0x3A444E), (0xD6D0C3, 0x433F37), (0xCACCD9, 0x3C3E52)]
        case .sidebarBorder: return [(0xDFDFDA, 0x2E2E2C), (0xE3DADE, 0x33292D), (0xDCE2E8, 0x2B3035), (0xE2DCCF, 0x302D28), (0xDDDFE9, 0x2C2E40)]
        case .accentPinkFg: return [(0xC2255C, 0xF06595), (0x4263EB, 0x91A7FF), (0xC2255C, 0xF06595), (0xC2255C, 0xF06595), (0xC2255C, 0xF06595)]
        case .accentPinkBg: return [(0xFCE4EC, 0x3A2229), (0xE7ECFF, 0x232A45), (0xFCE4EC, 0x3A2229), (0xFCE4EC, 0x3A2229), (0xFCE4EC, 0x3A2229)]
        case .accentTealFg: return [(0x0C7C8C, 0x4FC6D6), (0x0C7C8C, 0x4FC6D6), (0x0C7C8C, 0x4FC6D6), (0x0C7C8C, 0x4FC6D6), (0x0C7C8C, 0x4FC6D6)]
        case .accentTealBg: return [(0xDDF2F4, 0x1C3134), (0xDDF2F4, 0x1C3134), (0xDDF2F4, 0x1C3134), (0xDDF2F4, 0x1C3134), (0xDDF2F4, 0x1C3134)]
        case .accentGrayBg: return [(0xEEEEEA, 0x2B2B29), (0xF1ECEE, 0x302829), (0xEDF1F4, 0x292E33), (0xF0ECE3, 0x2F2C27), (0xEEEFF5, 0x2A2C3D)]
        }
    }
}

extension ThemeToken {
    /// The raw (light, dark) hex of this token in a palette.
    func value(in palette: FurlPalette) -> (light: UInt32, dark: UInt32) {
        let pair = values[FurlPalette.allCases.firstIndex(of: palette) ?? 0]
        return (pair.0, pair.1)
    }

    /// The fixed colour of this token in a given palette, for previews of palettes other than the
    /// current one (the Settings theme cards).
    func color(in palette: FurlPalette, dark: Bool) -> Color {
        let pair = values[FurlPalette.allCases.firstIndex(of: palette) ?? 0]
        return Color(nsColor: NSColor(hex: dark ? pair.1 : pair.0))
    }
}

extension Color {
    /// A token colour that follows the selected palette and the light/dark appearance.
    init(themed token: ThemeToken) {
        let values = token.values
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil
            let index = FurlPalette.allCases.firstIndex(of: FurlPalette.current) ?? 0
            let pair = values[index]
            return NSColor(hex: isDark ? pair.1 : pair.0)
        })
    }
}

/// Rebuilds a window's content when the palette changes, so every themed colour re-resolves.
/// Scan results live in AppState, so nothing of value is lost by the rebuild.
private struct PaletteScoped: ViewModifier {
    @AppStorage(FurlPalette.defaultsKey) private var palette = FurlPalette.mint.rawValue

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // 0.2 s ease-out crossfade between palettes; instant with Reduce Motion (ThemeSettings).
        ZStack {
            content
                .id(palette)
                .transition(.opacity)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: palette)
    }
}

extension View {
    func followsFurlPalette() -> some View { modifier(PaletteScoped()) }
}
