import AppKit

enum AsterAppearance: String {
    case dark, light, system

    static let initial: Self = .dark
}

struct AsterPalette {
    let page: NSColor
    let ink: NSColor
    let muted: NSColor
    let selection: NSColor
    let heading: NSColor
    let link: NSColor
    let emphasis: NSColor
    let code: NSColor
    let quote: NSColor
    let marker: NSColor

    static let dark = Self(page: 0x1c1921, ink: 0xf0e9f3, muted: 0xbdafc7, selection: 0x4c3f5d,
                           heading: 0xdbbfff, link: 0xacd7ff, emphasis: 0xf4b6d1,
                           code: 0xf6c0a9, quote: 0xb9e3cc, marker: 0xf1d5a2)
    static let light = Self(page: 0xfbf9fc, ink: 0x27232c, muted: 0x62596b, selection: 0xe6ddf0,
                            heading: 0x5d397b, link: 0x255583, emphasis: 0x86375f,
                            code: 0x843b2e, quote: 0x2d624f, marker: 0x73531e)

    private init(page: UInt32, ink: UInt32, muted: UInt32, selection: UInt32, heading: UInt32,
                 link: UInt32, emphasis: UInt32, code: UInt32, quote: UInt32, marker: UInt32) {
        self.page = Self.color(page)
        self.ink = Self.color(ink)
        self.muted = Self.color(muted)
        self.selection = Self.color(selection)
        self.heading = Self.color(heading)
        self.link = Self.color(link)
        self.emphasis = Self.color(emphasis)
        self.code = Self.color(code)
        self.quote = Self.color(quote)
        self.marker = Self.color(marker)
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: Double(hex >> 16) / 255,
                green: Double(hex >> 8 & 0xff) / 255,
                blue: Double(hex & 0xff) / 255, alpha: 1)
    }
}
