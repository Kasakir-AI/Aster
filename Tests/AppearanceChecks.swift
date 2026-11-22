import AppKit

@main @MainActor enum AppearanceChecks {
    static func main() async throws {
        _ = NSApplication.shared
        precondition(RenderOptions().arguments(preserveScroll: false)["appearance"] as? String == "dark",
                     "A preview with no preference should be dark")
        precondition(AsterAppearance(rawValue: "dark") == .dark
                     && AsterAppearance(rawValue: "light") == .light
                     && AsterAppearance(rawValue: "system") == .system,
                     "Saved appearances must retain their meaning")
        precondition(ReadingMode(rawValue: "Read") == .read
                     && ReadingMode(rawValue: "Write") == .styled
                     && ReadingMode(rawValue: "Source") == .source
                     && ReadingMode(rawValue: "Split") == .split,
                     "Saved view modes must retain their meaning")
        let suite = "aster-settings-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("light", forKey: "appearance")
        defaults.set(18.0, forKey: "fontSize")
        defaults.set(false, forKey: "restoreSession")
        defaults.set(true, forKey: "autoSave")
        defaults.set(false, forKey: "mermaid")
        defaults.set(false, forKey: "math")
        defaults.set(false, forKey: "frontMatter")
        defaults.set("Source", forKey: "viewMode")
        defaults.set(true, forKey: "didAskMarkdownDefault")
        defaults.set(["/notes/a.md"], forKey: "openDocuments")
        defaults.set("/notes/a.md", forKey: "selectedDocument")
        let folder = URL(fileURLWithPath: "/notes")
        defaults.set(folder, forKey: "workspace")
        defaults.set([Data([1, 2, 3])], forKey: "folderBookmarks")
        defaults.set(true, forKey: "workspaceLinksOnly")
        defaults.set(["/notes/a.md": "Split"], forKey: "documentViewModes")
        precondition(defaults.string(forKey: StoredSettings.appearance) == "light")
        precondition(defaults.object(forKey: StoredSettings.fontSize) as? Double == 18)
        precondition(defaults.object(forKey: StoredSettings.restoreSession) as? Bool == false)
        precondition(defaults.object(forKey: StoredSettings.autoSave) as? Bool == true)
        precondition(defaults.object(forKey: StoredSettings.mermaid) as? Bool == false)
        precondition(defaults.object(forKey: StoredSettings.math) as? Bool == false)
        precondition(defaults.object(forKey: StoredSettings.frontMatter) as? Bool == false)
        precondition(ReadingMode(rawValue: defaults.string(forKey: StoredSettings.viewMode) ?? "") == .source)
        precondition(defaults.object(forKey: StoredSettings.didAskMarkdownDefault) as? Bool == true)
        precondition(defaults.stringArray(forKey: StoredSettings.openDocuments) == ["/notes/a.md"])
        precondition(defaults.string(forKey: StoredSettings.selectedDocument) == "/notes/a.md")
        precondition(defaults.url(forKey: StoredSettings.workspace) == folder)
        precondition(defaults.array(forKey: StoredSettings.folderBookmarks) as? [Data] == [Data([1, 2, 3])])
        precondition(defaults.object(forKey: StoredSettings.workspaceLinksOnly) as? Bool == true)
        precondition(defaults.object(forKey: StoredSettings.documentViewModes) as? [String: String] == ["/notes/a.md": "Split"])
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
        editor.highlightNow()
        let source = editor.string as NSString
        func foreground(_ text: String) -> NSColor? {
            let index = source.range(of: text).location
            precondition(index != NSNotFound)
            return editor.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: index,
                                                            effectiveRange: nil) as? NSColor
        }

        precondition(editor.backgroundColor == AsterPalette.dark.page)
        let setext = foreground("Setext heading")
        precondition(setext == AsterPalette.dark.heading,
                     "Setext headings should be highlighted (saw \(setext?.description ?? "none"))")
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
        editor.highlightNow()
        precondition(editor.backgroundColor == AsterPalette.light.page)
        precondition(foreground("café") == AsterPalette.light.emphasis,
                     "Switching appearance must refresh existing highlights")
        try documentChecks()
        print("Appearance and document checks passed")
    }

    private static func documentChecks() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Note.md")
        let original = "# On disk"
        try Data(original.utf8).write(to: url)
        let model = Library()

        UserDefaults.standard.set(ReadingMode.read.rawValue, forKey: StoredSettings.viewMode)
        model.newNote()
        precondition(model.mode == .source, "New notes should open ready to type")
        model.open(url)
        precondition(model.mode == .read, "Creating a draft should not change the default view")

        let opened = model.active!
        model.open(folder.appending(path: "Missing.md"), line: 12)
        precondition(model.active === opened && model.jump == nil, "A failed open must not navigate the current note")

        model.root = folder
        let outside = folder.deletingLastPathComponent().appending(path: "Outside.md")
        UserDefaults.standard.set(true, forKey: StoredSettings.workspaceLinksOnly)
        precondition(model.canFollowLocalLink(url, from: url) && !model.canFollowLocalLink(outside, from: url),
                     "Workspace link navigation should stay inside the workspace")
        UserDefaults.standard.set(false, forKey: StoredSettings.workspaceLinksOnly)
        precondition(model.canFollowLocalLink(outside, from: url), "External links should follow the setting")

        opened.text = String(repeating: "é", count: 6 * 1024 * 1024 + 1)
        let didSave = model.save(opened, automatic: true)
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        precondition(!didSave && onDisk == original && opened.dirty,
                     "The encoded-size limit must preserve both the current file and the edited draft")

        model.open(PreviewTransfer.address(for: "First preview")!)
        let draft = model.active!
        draft.text = "Local draft"
        model.open(PreviewTransfer.address(for: "Second preview")!)
        let refreshed = model.active!
        precondition(refreshed !== draft && draft.dirty && draft.text == "Local draft",
                     "Incoming Xcode previews must preserve locally edited previews")
        model.open(PreviewTransfer.address(for: "Third preview")!)
        precondition(model.active === refreshed && refreshed.text == "Third preview" && !refreshed.dirty,
                     "Incoming Xcode previews may reuse a clean preview")
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
