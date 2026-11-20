import AppKit
import CoreText
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ reply: @escaping (QLThumbnailReply?, Error?) -> Void) {
        do {
            let source = try MarkdownFile.load(request.fileURL).text
            let size = request.maximumSize
            let rows = visibleLines(source)
            let headingIndex = rows.firstIndex(where: { $0.hasPrefix("# ") })
            let title = headingIndex.map { String(rows[$0].dropFirst(2)) } ?? request.fileURL.deletingPathExtension().lastPathComponent
            let excerpt = rows.enumerated().filter { $0.offset != headingIndex }.prefix(10)
                .map { _, row in
                    row.replacingOccurrences(of: #"^\s*(#{1,6}|>|[-+*]\s+\[[ xX]\]|[-+*])\s+"#,
                                             with: "", options: .regularExpression)
                }.joined(separator: "\n")
            reply(QLThumbnailReply(contextSize: size, drawing: { context in
                let scale = min(size.width, size.height) / 160
                let bounds = CGRect(origin: .zero, size: size)
                let palette = AsterPalette.dark
                context.setFillColor(palette.page.cgColor)
                context.fill(bounds)
                let inset = 15 * scale
                let top = size.height - 26 * scale
                Self.draw("✱", font: .systemFont(ofSize: 13 * scale, weight: .bold), color: palette.heading,
                          in: CGRect(x: inset, y: top, width: size.width - inset * 2, height: 15 * scale), context: context)
                Self.draw(String(title.prefix(90)), font: .systemFont(ofSize: 16 * scale, weight: .semibold),
                          color: palette.ink,
                          in: CGRect(x: inset, y: top - 42 * scale, width: size.width - inset * 2, height: 38 * scale), context: context)
                Self.draw(excerpt, font: .systemFont(ofSize: 8.5 * scale), color: palette.muted,
                          in: CGRect(x: inset, y: inset, width: size.width - inset * 2, height: max(0, top - 45 * scale - inset)), context: context)
                return true
            }), nil)
        } catch {
            reply(nil, error)
        }
    }

    private func visibleLines(_ source: String) -> [String] {
        let rows = source.prefix(6000).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let metadataEnd = rows.first == "---" ? rows.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) : nil
        var fence: Character?
        return rows.enumerated().compactMap { index, row in
            if let metadataEnd, index <= metadataEnd { return nil }
            if row.hasPrefix("```") || row.hasPrefix("~~~") {
                if fence == row.first { fence = nil } else if fence == nil { fence = row.first }
                return nil
            }
            return fence == nil && !row.isEmpty ? row : nil
        }
    }

    private static func draw(_ string: String, font: NSFont, color: NSColor, in rect: CGRect, context: CGContext) {
        let text = (try? AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            .map { String($0.characters) } ?? string
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color
        ])
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
    }
}
