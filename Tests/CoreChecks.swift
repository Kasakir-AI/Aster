import Foundation
import UniformTypeIdentifiers

@main enum CoreChecks {
    static func main() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let subfolder = workspace.appendingPathComponent("Guides", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let landing = workspace.appendingPathComponent("Start.md")
        let water = subfolder.appendingPathComponent("Café Notes.md")
        let markdown = """
        ---
        title: Test document
        ---
        # Getting started

        See [Water](Guides/Caf%C3%A9%20Notes.md#river) and [Missing](Missing.md).
        - [ ] Read the guide

        ```swift
        # This is not a heading
        ```

        [water]: <Guides/Café Notes.md>

            [Phantom](Phantom.md)
        """
        try markdown.write(to: landing, atomically: true, encoding: .utf8)
        try "# River\n\nFresh water observations.".write(to: water, atomically: true, encoding: .utf8)

        precondition(MarkdownFile.canBecomeDefault(UTType(filenameExtension: "md")!))
        precondition(MarkdownFile.canBecomeDefault(UTType("net.daringfireball.markdown")!))
        precondition(MarkdownFile.canBecomeDefault(.plainText))
        precondition(!MarkdownFile.canBecomeDefault(.folder))
        precondition(MarkdownFile.toggleTask(at: 7, in: markdown)?.contains("- [x] Read") == true)
        precondition(MarkdownFile.toggleTask(at: 9, in: markdown) == nil)
        precondition(MarkdownFile.toggleTask(at: 2, in: "🪻\r\n1. [X] Reviewed\r\n") == "🪻\r\n1. [ ] Reviewed\r\n")
        precondition(WorkspaceIndex.headings(in: markdown).map(\.line) == [4])
        let repeated = "# Hello, World!\n\n# Hello, World!\n\n# !!!\n"
        let anchors = WorkspaceIndex.headings(in: repeated).map(\.anchor)
        precondition(anchors == ["hello-world", "hello-world-1", "heading"], anchors.joined(separator: ","))
        precondition(WorkspaceIndex.heading(matching: "Getting-started", in: markdown)?.line == 4)
        let files = (1...40).map { URL(fileURLWithPath: String(format: "/notes/%02d.md", $0)) }
        let shown = WorkspaceIndex.visibleGraphNodes(focus: files[39], nodes: files)
        precondition(shown.first == files[39] && shown.count == 32 && !shown.dropFirst().contains(files[39]))
        let images = workspace.appendingPathComponent("Images", isDirectory: true)
        let outsideDir = workspace.appendingPathComponent("Images-secret", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        let note = images.appendingPathComponent("Note.txt")
        let inside = images.appendingPathComponent("inside.png")
        let outside = outsideDir.appendingPathComponent("secret.png")
        let bytes = Data([0x89, 0x50, 0x4e, 0x47])
        try bytes.write(to: inside)
        try bytes.write(to: outside)
        try Data("note".utf8).write(to: note)
        try FileManager.default.createSymbolicLink(at: images.appendingPathComponent("linked.png"), withDestinationURL: outside)
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))
        func asset(_ reference: String) -> URL {
            var components = URLComponents()
            components.scheme = "aster-asset"
            components.host = "image"
            components.percentEncodedPath = "/" + reference.addingPercentEncoding(withAllowedCharacters: allowed)!
            return components.url!
        }
        precondition(ImageAsset.read(asset("inside.png"), document: note, directory: images)?.data == bytes)
        precondition(ImageAsset.read(asset("../Images-secret/secret.png"), document: note, directory: images) == nil)
        precondition(ImageAsset.read(asset("linked.png"), document: note, directory: images) == nil)
        for encoding: MarkdownFile.Encoding in [.utf8, .utf8BOM, .utf16LE, .utf16BE] {
            let sample = "File encoding 🪻"
            let bytes = encoding.data(for: sample)!
            let target = workspace.appendingPathComponent("Encoding.test")
            try bytes.write(to: target)
            let content = try MarkdownFile.load(target)
            precondition(content.text == sample)
            precondition(content.encoding.data(for: content.text) == bytes)
        }
        let index = WorkspaceIndex.scan(workspace, unsaved: [:])
        precondition(index.tree.count == 2 && index.entries.count == 2)
        precondition(index.links.contains { $0.target == water && !$0.broken })
        precondition(index.links.filter(\.broken).map(\.target.lastPathComponent) == ["Missing.md"])
        precondition(index.links.filter { $0.target == water && !$0.broken }.count == 2)
        precondition(!index.links.contains { $0.address.contains("Phantom") })
        let results = try index.search("cafe observations", mode: .sections)
        precondition(results.first?.url == water && results.first?.line == 1)
        let regex = try index.search("FRESH.*water", mode: .regex)
        precondition(regex.first?.line == 3)
        let sample = String(repeating: markdown + "\n", count: 50)
        let address = PreviewTransfer.address(for: sample)
        precondition(address.flatMap(PreviewTransfer.source) == sample)
        precondition(PreviewTransfer.address(for: String(repeating: "a", count: 384_001)) == nil)
        print("Native checks passed")
    }
}
