import SwiftUI

/// A named list of hex colours. Palettes are purely presentational: nothing here
/// can change what the source image *is*, so they are free to be as loud as the
/// subject wants.
struct Palette: Identifiable, Hashable {
    let id: String
    let name: String
    let colors: [String]

    var count: Int { colors.count }
}

enum Palettes {
    /// Ink and paper, nothing between. The default, because the first subjects
    /// are pen doodles and for those the greys are the enemy: every
    /// anti-aliased edge in the source finds a comfortable mid-tone to land on,
    /// and you get a halo where you wanted an edge. Two colours forces a
    /// decision at every pixel, which is what makes it read as pixel art.
    static let mono = Palette(id: "mono", name: "Mono", colors: [
        "#ffffff", "#000000",
    ])

    /// Six greys. The default because the first subjects are pen doodles, and a
    /// hued palette on black-and-white line art produces coloured speckle: a mid
    /// grey lands nearest a cream if you let it.
    static let ink = Palette(id: "ink", name: "Ink", colors: [
        "#ffffff", "#c9ccd1", "#8b9199", "#4a5058", "#22262b", "#000000",
    ])

    static let earth = Palette(id: "earth", name: "Earth", colors: [
        "#5c3317", "#7b4b2a", "#8b5e3c", "#a0704b", "#2d6b12", "#3d8b24",
        "#4caf50", "#6ecf5c", "#505055", "#68686e", "#7c7c82", "#929298",
        "#c2a65a", "#d4be6a", "#e8d47a", "#f0e090", "#ffffff", "#000000",
    ])

    static let gameboy = Palette(id: "gameboy", name: "Game Boy", colors: [
        "#0f380f", "#306230", "#8bac0f", "#9bbc0f",
    ])

    static let pico = Palette(id: "pico", name: "Pico-8", colors: [
        "#000000", "#1d2b53", "#7e2553", "#008751", "#ab5236", "#5f574f",
        "#c2c3c7", "#fff1e8", "#ff004d", "#ffa300", "#ffec27", "#00e436",
        "#29adff", "#83769c", "#ff77a8", "#ffccaa",
    ])

    static let all: [Palette] = [mono, ink, earth, gameboy, pico]

    /// Built at runtime from the open image. Kept out of `all` because it only
    /// exists once something is loaded.
    static func extracted(_ colors: [String]) -> Palette {
        Palette(id: "extracted", name: "From image (\(colors.count))", colors: colors)
    }

    /// One step darker or lighter, the way pixel artists shade by hand: not
    /// just brightness. Darker also shifts hue toward blue and gains a little
    /// saturation, lighter shifts toward yellow and loses some, which is why a
    /// hand-shaded ramp looks lit rather than dimmed. Greys have no hue to
    /// shift and stay neutral.
    static func shade(_ hex: String, darker: Bool) -> String {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt32(s, radix: 16) ?? 0
        let r = Double((v >> 16) & 0xff) / 255, g = Double((v >> 8) & 0xff) / 255, b = Double(v & 0xff) / 255

        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h *= 60; if h < 0 { h += 360 }
        }
        var sat = mx == 0 ? 0 : d / mx
        var val = mx

        let grey = sat < 0.15
        if !grey {
            // Toward blue (240) when darker, yellow (60) when lighter, the
            // short way round, by at most 8 degrees.
            let target = darker ? 240.0 : 60.0
            var delta = (target - h).truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            h = (h + max(-8, min(8, delta)) + 360).truncatingRemainder(dividingBy: 360)
            sat = darker ? sat + (1 - sat) * 0.12 : sat * 0.85
        }
        val = darker ? val * 0.78 : val + (1 - val) * 0.4

        let c = val * sat, x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1)), m = val - c
        let (r1, g1, b1): (Double, Double, Double)
        switch h {
        case ..<60:  (r1, g1, b1) = (c, x, 0)
        case ..<120: (r1, g1, b1) = (x, c, 0)
        case ..<180: (r1, g1, b1) = (0, c, x)
        case ..<240: (r1, g1, b1) = (0, x, c)
        case ..<300: (r1, g1, b1) = (x, 0, c)
        default:     (r1, g1, b1) = (c, 0, x)
        }
        func byte(_ f: Double) -> Int { Int(((f + m) * 255).rounded()).clamped(0, 255) }
        return String(format: "#%02x%02x%02x", byte(r1), byte(g1), byte(b1))
    }

    static func color(_ hex: String) -> Color {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt32(s, radix: 16) ?? 0
        return Color(
            .sRGB,
            red: Double((v >> 16) & 0xff) / 255,
            green: Double((v >> 8) & 0xff) / 255,
            blue: Double(v & 0xff) / 255
        )
    }
}

private extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}
