<img src="Docs/Aster.png" width="108" height="108" alt="Aster icon">

# Aster

Aster is a native macOS editor and reader for Markdown. Open a single file or work through a folder of notes. Finder can show a rendered preview when you press Space, even while Aster is closed.

## What you can do

- Read, write, edit source, or see the source and preview side by side with synchronized scrolling.
- Render tables, task lists, syntax-highlighted code, Mermaid diagrams, math, and YAML front matter offline.
- Browse a folder in tabs, jump to headings, search sections or matching lines, and inspect backlinks and broken document links.
- Edit with native find and replace, formatting shortcuts, focus mode, and typewriter mode.
- Print a preview or export it as HTML or PDF.

Aster works with plain Markdown files on disk. It displays local images from the document folder or the open workspace. It leaves remote images unloaded.

## Install

Aster targets macOS 14 and later on Apple silicon and Intel. Download the ZIP from [Releases](https://github.com/Kasakir-AI/Aster/releases), extract it, and move Aster to Applications. Launch it once to register its extensions.

Finder Quick Look renders math and displays Mermaid blocks as source. Open the file in Aster to see the diagram.


The download is ad hoc signed and unnotarized. If macOS blocks the download, build and run Aster locally using the instructions below.

### Finder Quick Look

In Finder, select a Markdown file and press Space. If Finder shows raw text, look for **Aster Markdown Preview** under **System Settings → General → Login Items & Extensions → Quick Look**. Check for another enabled Markdown preview provider if Finder still shows a different preview.

### Xcode

Enable **Aster for Xcode** under **System Settings → General → Login Items & Extensions → Xcode Source Editor**, then restart Xcode. Open a Markdown file and choose **Editor → Aster for Xcode → Preview Buffer in Aster**. The command opens the current text as a separate preview, including unsaved edits.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘O | Open Markdown |
| ⇧⌘O | Open a workspace |
| ⌘T | Open Quickly |
| ⇧⌘R | Cycle Read, Write, Source, and Split |
| ⌘F | Find in the current document |
| ⌥⌘F | Find and replace in the editor |
| ⇧⌘F | Search the workspace |
| ⇧⌘G | Open the Link Map |
| ⇧⌘E | Export PDF from a preview |

## Build

Install Xcode 16 or later and Node.js 22 or later. From the repository root, run the build.

```sh
./build.sh
open .build/Xcode/Build/Products/Release/Aster.app
```

The build installs the locked renderer dependencies, runs the tests, and creates a universal app bundle. Run `./test.sh` to repeat the tests after installing those dependencies.

Aster is available under the [MIT license](LICENSE). The app bundle includes notices for third-party packages.
