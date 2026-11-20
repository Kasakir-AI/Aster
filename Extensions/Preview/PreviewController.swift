import Foundation
import JavaScriptCore
import os
import QuickLookUI
import UniformTypeIdentifiers

final class PreviewController: QLPreviewProvider, QLPreviewingController {
    private let logger = Logger(subsystem: "io.github.kasakir-ai.aster", category: "QuickLook")

    func providePreview(for request: QLFilePreviewRequest, completionHandler: @escaping (QLPreviewReply?, Error?) -> Void) {
        let url = request.fileURL
        completionHandler(QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 820, height: 680)) { [logger] reply in
            let preview = try Self.render(url)
            reply.attachments = preview.attachments
            logger.notice("Finished rendering a Markdown preview")
            return preview.data
        }, nil)
    }

    private static func render(_ url: URL) throws -> (data: Data, attachments: [String: QLPreviewReplyAttachment]) {
        let source = try MarkdownFile.load(url).text
        guard let scriptURL = Bundle.main.url(forResource: "quicklook", withExtension: "js", subdirectory: "Bundle"),
              let cssURL = Bundle.main.url(forResource: "paper", withExtension: "css", subdirectory: "Bundle"),
              let context = JSContext() else { throw CocoaError(.fileReadCorruptFile) }
        context.evaluateScript(try String(contentsOf: scriptURL, encoding: .utf8), withSourceURL: scriptURL)
        guard let rendered = context.objectForKeyedSubscript("renderQuickLook")?.call(withArguments: [source]),
              !rendered.isUndefined, !rendered.isNull, let body = rendered.toString() else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let directory = url.deletingLastPathComponent()
        var attachments: [String: QLPreviewReplyAttachment] = [:]
        let content = ImageAsset.replacingSources(in: body) { address in
            guard let image = ImageAsset.read(address, document: url, directory: directory),
                  let type = UTType(mimeType: image.mime) else { return nil }
            let key = "image-\(attachments.count)"
            attachments[key] = QLPreviewReplyAttachment(data: image.data, contentType: type)
            return "cid:" + key
        }
        let css = try String(contentsOf: cssURL, encoding: .utf8)
        let html = """
        <!doctype html><html lang="en"><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src cid:; base-uri 'none'; form-action 'none'">
        <style>\(css)</style><article>\(content)</article></html>
        """
        return (Data(html.utf8), attachments)
    }
}
