# Changelog

## Unreleased

- HTML, PDF, and print output reflect the selected draft, including unsaved edits.
- If a file changes again before you replace it, Aster asks you to review the new change.
- Aster can reopen a workspace after you rename its folder.
- The Link Map follows the workspace-only link setting.
- The Mac App Store build uses App Store updates. Aster Settings links to the privacy policy.

## 1.0.2

- The disk image now includes Apple’s notarization ticket on the Aster app as well as the disk image. This keeps Finder Quick Look working after installation from the disk image.

## 1.0.1

- Aster’s macOS downloads are signed with Developer ID and notarized by Apple.

## 1.0.0

- The editor runs in the sandbox and remembers folders and files you open. Images stored next to a note still appear.
- Settings can keep document links inside the workspace. The setting starts off.
- Help includes Report a Bug and Request a Feature. Each opens a GitHub issue with the Aster version filled in.
- Settings states that notes stay on this Mac. Check for Updates looks for a newer GitHub release and does not install it.
- A wikilink such as `[[Note]]` opens another note in the workspace.
- A code block in the preview has a Copy button.
- The status bar shows the word count for the open note.
- Each document remembers the view mode you used for it.

## 0.2.3

- Choosing Aster for Markdown files completes when Finder opens .md files in Aster. A Markdown type that macOS refuses to reassign no longer shows an error.

## 0.2.2

- A heading link opens that heading when the link uses different capital letters.
- The preview stays on the paragraph you were reading when Aster draws a Mermaid diagram above it.
- The link map includes reference links and paths with spaces. It ignores links written in indented code.
- Backlinks update while you type.
- Preview Buffer in Aster reuses one preview. The view mode saved for the next launch stays as it was.
- Finder Quick Look shows images stored in the same folder as the note.
- The link map keeps the selected file on the graph.
- The first launch asks whether Finder should open Markdown files in Aster. You can choose this later in Settings.

## 0.2.1

- A link to a heading opens that heading, including when the heading contains punctuation or the same text appears twice.

## 0.2.0

- Start in a dark pastel theme in the app and Finder Quick Look. The app can still follow macOS or use Light mode.
- Use coordinated, higher-contrast colors for Markdown syntax, links, and code.
- Install from a drag-and-drop DMG or through the Homebrew tap. The ZIP is still available.

## 0.1.0

- Added formatted Finder Quick Look previews and document thumbnails for Markdown files.
- Added reading, writing, source, and split views with syntax highlighting, clickable task lists, and local image support.
- Added offline Mermaid diagrams and math rendering.
- Added workspace tabs, heading navigation, search, and a link map with broken-link checks.
- Added print, HTML and PDF export, and an Xcode preview command.
