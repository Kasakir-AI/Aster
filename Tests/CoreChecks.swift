import Foundation

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
        """
        try markdown.write(to: landing, atomically: true, encoding: .utf8)
        try "# River\n\nFresh water observations.".write(to: water, atomically: true, encoding: .utf8)

        precondition(MarkdownFile.toggleTask(at: 7, in: markdown)?.contains("- [x] Read") == true)
        precondition(MarkdownFile.toggleTask(at: 9, in: markdown) == nil)
        precondition(MarkdownFile.toggleTask(at: 2, in: "🪻\r\n1. [X] Reviewed\r\n") == "🪻\r\n1. [ ] Reviewed\r\n")
        precondition(WorkspaceIndex.headings(in: markdown).map(\.line) == [4])
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
