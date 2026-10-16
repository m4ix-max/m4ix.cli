import AppKit
import CoreText
import SwiftUI

/// Colour, type and spacing tokens for this macOS utility.
///
/// Type is Newsreader and Chivo Mono, bundled in Resources/Fonts under the
/// SIL Open Font License; Georgia and the system monospace stand in if the
/// files cannot be loaded.
enum HostTheme {
    // MARK: Colour

    private static let solidInk = nsColor(0x141414)
    private static let solidPaper = nsColor(0xEBEAEA)

    // These are surface and text roles. In dark appearance the inverse
    // tokens become the default chrome, while the terminal stays ink on paper.
    static let nsInk = adaptive(light: solidInk, dark: solidPaper)
    static let nsPaper = adaptive(light: solidPaper, dark: solidInk)
    static let nsPaperDeep = adaptive(light: nsColor(0xD7D5D5), dark: nsColor(0x292929))
    static let nsCharcoal = nsColor(0x292929)
    static let nsGraphite = adaptive(light: nsColor(0x535050), dark: nsColor(0xAFADAC))
    static let nsAsh = nsColor(0xAFADAC)
    static let nsSignal = nsColor(0xE8FA51)
    /// Marks drawn on the signal colour stay ink in either appearance.
    static let nsOnSignal = solidInk
    static let nsViolet = nsColor(0xA082F0)
    /// Running text in chat, a step below ink: about 10:1 against paper
    /// rather than 15:1, so long replies do not glare. Bold and headings
    /// keep ink and stand out from it.
    static let nsReading = adaptive(light: nsColor(0x3A3838), dark: nsColor(0xC2C0BD))

    static let inkNS = nsInk
    static let paperNS = nsPaper
    static let signalNS = nsSignal

    static let ink = Color(nsColor: nsInk)
    static let paper = Color(nsColor: nsPaper)
    static let paperDeep = Color(nsColor: nsPaperDeep)
    static let charcoal = Color(nsColor: nsCharcoal)
    static let graphite = Color(nsColor: nsGraphite)
    static let ash = Color(nsColor: nsAsh)
    static let signal = Color(nsColor: nsSignal)
    static let onSignal = Color(nsColor: nsOnSignal)
    static let violet = Color(nsColor: nsViolet)
    static let reading = Color(nsColor: nsReading)

    /// Each provider's name and mark in chat. The light values are deeper
    /// so the 12-point name still reads on paper.
    static let claude = Color(nsColor: adaptive(light: nsColor(0xB5532F), dark: nsColor(0xD97757)))
    static let codex = Color(nsColor: adaptive(light: nsColor(0x0E7480), dark: nsColor(0x56C2C9)))
    static let hermes = Color(nsColor: adaptive(light: nsColor(0x7149B8), dark: nsViolet))

    /// The semantic hairlines in the source tokens use 8-bit alpha values.
    static let nsBorder = adaptive(
        light: nsColor(0x141414, alpha: 0x3D),
        dark: nsColor(0xEBEAEA, alpha: 0x52)
    )
    static let nsBorderSubtle = adaptive(
        light: nsColor(0x141414, alpha: 0x24),
        dark: nsColor(0xEBEAEA, alpha: 0x24)
    )
    static let nsBorderInverse = nsColor(0xEBEAEA, alpha: 0x52)
    static let border = Color(nsColor: nsBorder)
    static let borderSubtle = Color(nsColor: nsBorderSubtle)
    static let borderInverse = Color(nsColor: nsBorderInverse)

    static let terminalBackground = solidInk
    static let terminalForeground = solidPaper

    // MARK: Geometry

    /// The conversation column: about 100 characters of chat text a line.
    static let readingWidth: CGFloat = 760
    static let spacing8: CGFloat = 8
    static let spacing16: CGFloat = 16
    static let spacing24: CGFloat = 24
    static let spacing32: CGFloat = 32
    static let hairlineWidth: CGFloat = 1
    static let controlRadius: CGFloat = 4

    // MARK: Typography

    static func serif(_ size: CGFloat) -> Font {
        Font(serifNS(size) as CTFont)
    }

    /// Newsreader's optical size follows the point size, so sidebar lines and
    /// titles each get the cut drawn for them.
    static func serifNS(_ size: CGFloat) -> NSFont {
        bundledFont("Newsreader", size: size, axes: ["wght": 400, "opsz": min(max(size, 6), 72)])
            ?? NSFont(name: "Georgia", size: size)
            ?? .systemFont(ofSize: size)
    }

    /// Chivo Mono has lowercase letters, so label text must be written in
    /// capitals or uppercased where it is set.
    static func utility(_ size: CGFloat, medium: Bool = false) -> Font {
        Font(utilityNS(size, medium: medium) as CTFont)
    }

    static func utilityNS(_ size: CGFloat, medium: Bool = false) -> NSFont {
        bundledFont("ChivoMono", size: size, axes: ["wght": medium ? 500 : 400])
            ?? .monospacedSystemFont(ofSize: size, weight: medium ? .medium : .regular)
    }

    /// Both faces are variable fonts. Chivo Mono's named weights carry no
    /// PostScript names, so weight and optical size are set on the axes.
    private static func bundledFont(_ name: String, size: CGFloat, axes: [String: CGFloat]) -> NSFont? {
        guard let face = bundledFaces[name] else { return nil }
        var variation: [NSNumber: NSNumber] = [:]
        for (tag, value) in axes {
            let code = tag.unicodeScalars.reduce(UInt32(0)) { $0 << 8 | $1.value }
            variation[NSNumber(value: code)] = NSNumber(value: Double(value))
        }
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            face, [kCTFontVariationAttribute: variation] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
    }

    /// Registered for this process only, so the faces never reach the user's
    /// font list.
    private static let bundledFaces: [String: CTFontDescriptor] = {
        var faces: [String: CTFontDescriptor] = [:]
        for name in ["Newsreader", "ChivoMono"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
                // SwiftPM places resources in a sibling bundle when running `swift run`.
                ?? Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") else { continue }
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            if let descriptor = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first {
                faces[name] = descriptor
            }
        }
        return faces
    }()

    private static func nsColor(_ hex: Int, alpha: Int = 0xFF) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: CGFloat(alpha) / 255
        )
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

/// A restrained hover and press response for the app's custom chrome buttons.
/// Native controls keep their platform appearance; plain buttons use this style
/// so pointer affordance remains visible without changing the palette.
struct HoverButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: HostTheme.controlRadius)
                    .fill(HostTheme.ink.opacity(configuration.isPressed ? 0.10 : (isHovered ? 0.055 : 0)))
                    .allowsHitTesting(false)
            }
            .scaleEffect(configuration.isPressed && isEnabled ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.48)
            .contentShape(RoundedRectangle(cornerRadius: HostTheme.controlRadius))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
