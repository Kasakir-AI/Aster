import Foundation
import UniformTypeIdentifiers

enum ImageAsset {
    static func read(_ address: URL, document: URL, directory: URL) -> (mime: String, data: Data)? {
        guard address.scheme == "aster-asset", address.host == "image",
              let encoded = URLComponents(url: address, resolvingAgainstBaseURL: false)?.percentEncodedPath.dropFirst(),
              let reference = String(encoded).removingPercentEncoding,
              let url = MarkdownFile.localURL(reference, relativeTo: document)?.resolvingSymlinksInPath(),
              url.path.hasPrefix(directory.resolvingSymlinksInPath().path + "/"),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 20 * 1024 * 1024,
              let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
              let mime = type.preferredMIMEType,
              let data = try? Data(contentsOf: url) else { return nil }
        return (mime, data)
    }

    static func replacingSources(in html: String, with replacement: (URL) -> String?) -> String {
        var output = html
        for match in html.matches(of: /src="(aster-asset:\/\/image\/[^"]+)"/).reversed() {
            guard let url = URL(string: String(match.1)), let newSource = replacement(url) else { continue }
            let position = NSRange(match.1.startIndex..<match.1.endIndex, in: html)
            guard let range = Range(position, in: output) else { continue }
            output.replaceSubrange(range, with: newSource)
        }
        return output
    }
}
