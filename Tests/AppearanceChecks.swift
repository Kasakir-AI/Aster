import AppKit

@main @MainActor enum AppearanceChecks {
    static func main() async throws {
        _ = NSApplication.shared
        precondition(RenderOptions().arguments(preserveScroll: false)["appearance"] as? String == "dark",
                     "A preview with no preference should be dark")
        precondition(AsterAppearance(rawValue: "light") == .light && AsterAppearance(rawValue: "system") == .system,
                     "Saved appearances must retain their meaning")
        for palette in [AsterPalette.dark, .light] {
            let text = [palette.ink, palette.muted, palette.heading, palette.link,
                        palette.emphasis, palette.code, palette.quote, palette.marker]
            for foreground in text {
                for background in [palette.page, palette.selection] {
                    precondition(contrast(foreground, background) >= 4.5, "Editor text must have 4.5:1 contrast")
                }
            }
        }
        let editor = SourceTextView(frame: .zero)
        editor.setEditorFont(size: 14)
        editor.setEditorAppearance(dark: true)
        editor.string = """
        Setext heading
        ==============

        # ATX heading
        ---

        🪻 *café* and [reference][place] plus ~~a draft~~

        [place]: /notes

        ~~~~swift
        # inside the fence
        ~~~
        > still code
        ~~~~

        > actually a quote
        """
        editor.highlight()
        try await Task.sleep(for: .milliseconds(140))
        let source = editor.string as NSString
        func foreground(_ text: String) -> NSColor? {
            let index = source.range(of: text).location
            precondition(index != NSNotFound)
            return editor.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: index,
                                                            effectiveRange: nil) as? NSColor
        }

        precondition(editor.backgroundColor == AsterPalette.dark.page)
        precondition(foreground("Setext heading") == AsterPalette.dark.heading, "Setext headings should be highlighted")
        precondition(foreground("======") == AsterPalette.dark.heading, "A Setext underline belongs to its heading")
        precondition(foreground("---") != AsterPalette.dark.heading, "A thematic break cannot underline an ATX heading")
        precondition(foreground("café") == AsterPalette.dark.emphasis, "Highlighting should follow Unicode source positions")
        precondition(foreground("reference") == AsterPalette.dark.link, "Reference links should be highlighted")
        precondition(foreground("a draft") == AsterPalette.dark.emphasis, "GFM strikethrough should be highlighted")
        precondition(foreground("inside the fence") == AsterPalette.dark.code,
                     "Fenced code must not appear as a heading")
        precondition(foreground("still code") == foreground("inside the fence"),
                     "A shorter delimiter must not close a code fence")
        precondition(foreground("actually a quote") == AsterPalette.dark.quote,
                     "Quoting must resume after a fence closes")
        editor.setEditorAppearance(dark: false)
        editor.highlight()
        try await Task.sleep(for: .milliseconds(140))
        precondition(editor.backgroundColor == AsterPalette.light.page)
        precondition(foreground("café") == AsterPalette.light.emphasis,
                     "Switching appearance must refresh existing highlights")
        print("Appearance checks passed")
    }

    private static func contrast(_ first: NSColor, _ second: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            let channels = [color.redComponent, color.greenComponent, color.blueComponent].map { channel in
                channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
        }
        let a = luminance(first)
        let b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
