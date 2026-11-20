import Foundation
import UniformTypeIdentifiers

enum StoredSettings {
    static let appearance = "appearance"
    static let fontSize = "fontSize"
    static let restoreSession = "restoreSession"
    static let autoSave = "autoSave"
    static let mermaid = "mermaid"
    static let math = "math"
    static let frontMatter = "frontMatter"
    static let viewMode = "viewMode"
    static let didAskMarkdownDefault = "didAskMarkdownDefault"
    static let workspace = "workspace"
    static let openDocuments = "openDocuments"
    static let selectedDocument = "selectedDocument"
    static let folderBookmarks = "folderBookmarks"
    static let workspaceLinksOnly = "workspaceLinksOnly"
    static let documentViewModes = "documentViewModes"
}

enum DocumentModes {
    static func raw(for path: String, in modes: [String: String]) -> String? {
        modes[path]
    }

    static func remembering(_ raw: String, for path: String, in modes: [String: String]) -> [String: String] {
        var copy = modes
        copy[path] = raw
        return copy
    }
}

enum FolderAccess {
    static func contains(_ url: URL, in folder: URL) -> Bool {
        let file = url.resolvingSymlinksInPath().standardizedFileURL
        let directory = folder.resolvingSymlinksInPath().standardizedFileURL
        return file == directory || file.path.hasPrefix(directory.path.hasSuffix("/") ? directory.path : directory.path + "/")
    }

    static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolve(_ data: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    static func linkStaysInside(_ target: URL, workspace: URL?, document: URL) -> Bool {
        contains(target, in: workspace ?? document.deletingLastPathComponent())
    }
}

enum IssueReport {
    static func url(feature: Bool, version: String) -> URL? {
        var components = URLComponents(string: "https://github.com/Kasakir-AI/Aster/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: feature ? "Feature request" : "Bug report"),
            URLQueryItem(name: "body", value: "Aster \(version)\n\n"),
        ]
        return components?.url
    }
}

enum ReleaseLookup {
    static let latest = URL(string: "https://api.github.com/repos/Kasakir-AI/Aster/releases/latest")!
    static let releases = URL(string: "https://github.com/Kasakir-AI/Aster/releases/latest")!

    static func version(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        let number = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let parts = number.split(separator: ".")
        guard parts.count == 3, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return number
    }

    static func isNewer(_ latest: String, than current: String) -> Bool {
        let left = latest.split(separator: ".").compactMap { Int($0) }
        let right = current.split(separator: ".").compactMap { Int($0) }
        guard left.count == 3, right.count == 3 else { return false }
        return left.lexicographicallyPrecedes(right) == false && left != right
    }
}

enum MarkdownFile {
    static let extensions = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt"]
    static let type = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)

    static func isMarkdown(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// macOS accepts a default-app change for file types. `public.markdown` is declared with
    /// filename extensions but does not conform to `public.data`, and Launch Services refuses
    /// `setDefaultApplication` for it.
    static func canBecomeDefault(_ type: UTType) -> Bool {
        type.conforms(to: .data)
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
