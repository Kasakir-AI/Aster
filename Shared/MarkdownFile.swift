import Foundation
import UniformTypeIdentifiers

enum MarkdownFile {
    static let extensions = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt"]
    static let type = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)

    static func isMarkdown(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    enum Encoding {
        case utf8, utf8BOM, utf16LE, utf16BE, legacy(String.Encoding)

        func data(for text: String) -> Data? {
            switch self {
            case .utf8: Data(text.utf8)
            case .utf8BOM: Data([0xef, 0xbb, 0xbf]) + Data(text.utf8)
            case .utf16LE: text.data(using: .utf16LittleEndian).map { Data([0xff, 0xfe]) + $0 }
            case .utf16BE: text.data(using: .utf16BigEndian).map { Data([0xfe, 0xff]) + $0 }
            case .legacy(let encoding): text.data(using: encoding)
            }
        }
    }

    static func load(_ url: URL) throws -> (text: String, encoding: Encoding) {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 12 * 1024 * 1024 else {
            throw CocoaError(.fileReadTooLarge, userInfo: [NSURLErrorKey: url])
        }
        let data = try Data(contentsOf: url)
        if data.starts(with: [0xff, 0xfe]), let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return (text, .utf16LE)
        }
        if data.starts(with: [0xfe, 0xff]), let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return (text, .utf16BE)
        }
        if data.starts(with: [0xef, 0xbb, 0xbf]), let text = String(data: data.dropFirst(3), encoding: .utf8) {
            return (text, .utf8BOM)
        }
        if let text = String(data: data, encoding: .utf8) {
            return (text, .utf8)
        }
        var encoding = String.Encoding.utf8
        let text = try String(contentsOf: url, usedEncoding: &encoding)
        return (text, .legacy(encoding))
    }

    static func localURL(_ address: String, relativeTo document: URL) -> URL? {
        let path = String(address.prefix { $0 != "#" && $0 != "?" })
        guard !path.isEmpty, !path.hasPrefix("/"),
              URLComponents(string: path)?.scheme == nil,
              let decoded = path.removingPercentEncoding, !decoded.hasPrefix("/") else { return nil }
        return document.deletingLastPathComponent().appendingPathComponent(decoded).standardizedFileURL
    }

    static func range(ofLine line: Int, in source: String) -> NSRange? {
        guard line > 0 else { return nil }
        let text = source as NSString
        var position = 0
        for _ in 1..<line {
            guard position < text.length else { return nil }
            position = NSMaxRange(text.lineRange(for: NSRange(location: position, length: 0)))
        }
        return text.lineRange(for: NSRange(location: position, length: 0))
    }

    static func toggleTask(at line: Int, in source: String) -> String? {
        guard let range = range(ofLine: line, in: source) else { return nil }
        let text = source as NSString
        let row = text.substring(with: range)
        let marker = /^[\s>]*(?:[-+*]|\d+[.)])\s+\[([ xX])\](?=\s|$)/
        guard let match = row.firstMatch(of: marker),
              let location = match.1.startIndex.samePosition(in: row.utf16) else { return nil }
        let offset = row.utf16.distance(from: row.utf16.startIndex, to: location)
        return text.replacingCharacters(in: NSRange(location: range.location + offset, length: 1),
                                       with: match.1 == " " ? "x" : " ")
    }
}
