import Foundation

struct Heading: Identifiable {
    var id: Int { line }
    let line: Int
    let level: Int
    let title: String
    let anchor: String
}

struct SearchHit: Identifiable {
    var id: String { url.path + "#" + String(line) }
    let url: URL
    let line: Int
    let title: String
    let excerpt: String
    let score: Int
}

struct DocumentLink: Identifiable {
    var id: String { source.path + "#" + String(ordinal) }
    let source: URL
    let target: URL
    let address: String
    let broken: Bool
    let ordinal: Int
}

struct FileNode: Identifiable {
    var id: URL { url }
    let url: URL
    var children: [FileNode]?
}

enum SearchMode: String, CaseIterable, Identifiable {
    case sections = "Sections", lines = "Exact lines", regex = "Regex"
    var id: Self { self }
}

struct WorkspaceIndex {
    let entries: [Entry]
    let links: [DocumentLink]
    let tree: [FileNode]

    struct Entry {
        let url: URL
        let source: String
        let headings: [Heading]
    }

    static let empty = WorkspaceIndex(entries: [], links: [], tree: [])

    static func scan(_ root: URL, unsaved: [URL: String]) -> Self {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return .empty }
        var entries: [Entry] = []
        for case let url as URL in files {
            if Task.isCancelled { return .empty }
            if ["node_modules", "vendor", "DerivedData"].contains(url.lastPathComponent) && !MarkdownFile.isMarkdown(url) {
                files.skipDescendants()
            }
            guard MarkdownFile.isMarkdown(url), (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let source = unsaved[url.standardizedFileURL] ?? (try? MarkdownFile.load(url).text) else { continue }
            entries.append(.init(url: url.standardizedFileURL, source: source, headings: headings(in: source)))
        }
        entries.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        let addresses = Set(entries.map(\.url))
        let links = entries.flatMap { entry in
            let matches = proseLines(entry.source).flatMap { _, row in linkAddresses(on: row) }
            return matches.enumerated().compactMap { ordinal, address -> DocumentLink? in
                guard let target = MarkdownFile.localURL(address, relativeTo: entry.url), MarkdownFile.isMarkdown(target) else { return nil }
                return DocumentLink(source: entry.url, target: target, address: address,
                                    broken: !addresses.contains(target) && !FileManager.default.fileExists(atPath: target.path),
                                    ordinal: ordinal)
            }
        }
        var children: [URL: [FileNode]] = [:]
        var folders: Set<URL> = []
        for entry in entries {
            var folder = entry.url.deletingLastPathComponent().standardizedFileURL
            children[folder, default: []].append(FileNode(url: entry.url))
            while folder != root && folder.path.hasPrefix(root.path + "/") {
                folders.insert(folder)
                folder = folder.deletingLastPathComponent().standardizedFileURL
            }
        }
        for folder in folders.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            children[folder.deletingLastPathComponent().standardizedFileURL, default: []]
                .append(FileNode(url: folder, children: sorted(children[folder] ?? [])))
        }
        return Self(entries: entries, links: links, tree: sorted(children[root] ?? []))
    }

    static func heading(matching fragment: String, in source: String) -> Heading? {
        let value = (fragment.removingPercentEncoding ?? fragment).lowercased(with: nil)
        return headings(in: source).first { $0.anchor == value }
    }

    static func visibleGraphNodes(focus: URL?, nodes: [URL], limit: Int = 32) -> [URL] {
        guard let focus else { return Array(nodes.prefix(limit)) }
        return Array(([focus] + nodes.filter { $0 != focus }).prefix(limit))
    }

    static func headings(in source: String) -> [Heading] {
        var output: [Heading] = []
        var taken: Set<String> = []
        var previous: (Int, String)?
        for (line, row) in proseLines(source) {
            if let match = row.firstMatch(of: /^ {0,3}(#{1,6})[ \t]+(.+?) *#* *$/) {
                output.append(heading(line: line, level: match.1.count, title: plainTitle(String(match.2)), taken: &taken))
                previous = nil
            } else if let prior = previous, prior.0 + 1 == line,
                      let underline = row.firstMatch(of: /^ {0,3}(=+|-+)\s*$/), !prior.1.isEmpty,
                      !prior.1.hasPrefix("#"), !prior.1.hasPrefix(">") {
                output.append(heading(line: prior.0, level: underline.1.first == "=" ? 1 : 2,
                                      title: plainTitle(prior.1), taken: &taken))
                previous = nil
            } else {
                previous = (line, row.trimmingCharacters(in: .whitespaces))
            }
        }
        return output
    }

    private static func anchor(for title: String, taken: inout Set<String>) -> String {
        let base = slug(title)
        var anchor = base
        var suffix = 1
        while taken.contains(anchor) {
            anchor = base + "-" + String(suffix)
            suffix += 1
        }
        taken.insert(anchor)
        return anchor
    }

    private static func heading(line: Int, level: Int, title: String, taken: inout Set<String>) -> Heading {
        Heading(line: line, level: level, title: title, anchor: anchor(for: title, taken: &taken))
    }

    private static func slug(_ title: String) -> String {
        let folded = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: nil)
        var cleaned = ""
        for character in folded {
            if character.isLetter || character.isNumber || character == "_" || character == "-" {
                cleaned.append(character)
            } else if character.isWhitespace {
                cleaned.append("-")
            }
        }
        return cleaned.isEmpty ? "heading" : cleaned
    }

    private static func plainTitle(_ text: String) -> String {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnly)))
            .map { String($0.characters) } ?? text
    }

    static func linkAddresses(on row: String) -> [String] {
        guard !isIndentedCode(row) else { return [] }
        var found: [String] = []
        for match in row.matches(of: /(?:^|[^!])\]\((?:<([^>\n]+)>|([^)\s]+))/) {
            if let bracketed = match.output.1 { found.append(String(bracketed)) }
            else if let plain = match.output.2 { found.append(String(plain)) }
        }
        if let reference = row.firstMatch(of: /^ {0,3}\[[^\]\n]+\]:[ \t]+(?:<([^>\n]+)>|(\S+))/) {
            if let bracketed = reference.output.1 { found.append(String(bracketed)) }
            else if let plain = reference.output.2 { found.append(String(plain)) }
        }
        return found
    }

    private static func isIndentedCode(_ row: String) -> Bool {
        var width = 0
        var index = row.startIndex
        while index < row.endIndex, row[index] == " " || row[index] == "\t" {
            width += row[index] == "\t" ? 4 : 1
            index = row.index(after: index)
        }
        guard width >= 4, index < row.endIndex else { return false }
        let rest = row[index...]
        return rest.firstMatch(of: /^(?:[-+*]|\d+[.)])[ \t]/) == nil
    }

    static func proseLines(_ source: String) -> [(Int, String)] {
        let rows = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let metadataEnd = rows.first?.trimmingCharacters(in: .whitespaces) == "---"
            ? rows.dropFirst().firstIndex(where: { ["---", "..."].contains($0.trimmingCharacters(in: .whitespaces)) }) : nil
        var fence: (character: Character, length: Int)?
        var output: [(Int, String)] = []
        for (index, row) in rows.enumerated() {
            if let metadataEnd, index <= metadataEnd { continue }
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            if let delimiter = trimmed.first, delimiter == "~" || delimiter == "`" {
                let length = trimmed.prefix(while: { $0 == delimiter }).count
                if length >= 3 {
                    if let current = fence {
                        if current.character == delimiter && length >= current.length && trimmed.count == length { fence = nil }
                    } else { fence = (delimiter, length) }
                    continue
                }
            }
            if fence == nil { output.append((index + 1, row)) }
        }
        return output
    }

    func search(_ query: String, mode: SearchMode) throws -> [SearchHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let regex = mode == .regex ? try NSRegularExpression(pattern: query, options: .caseInsensitive) : nil
        let words = Self.fold(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let results = entries.flatMap { entry -> [SearchHit] in
            let name = entry.url.deletingPathExtension().lastPathComponent
            let lines = entry.source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
            if mode != .sections {
                return lines.enumerated().compactMap { index, text in
                    let matched = regex.map {
                        $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                    } ?? text.localizedStandardContains(query)
                    return matched ? SearchHit(url: entry.url, line: index + 1, title: name, excerpt: String(text.prefix(240)), score: 1) : nil
                }
            }
            guard !words.isEmpty else { return [] }
            var sections = entry.headings.filter { $0.line <= lines.count }
            if sections.first?.line != 1 {
                sections.insert(Heading(line: 1, level: 0, title: name, anchor: Self.slug(name)), at: 0)
            }
            return sections.enumerated().compactMap { index, heading -> SearchHit? in
                let limit = index + 1 == sections.count ? lines.count : sections[index + 1].line - 1
                let rows = lines[(heading.line - 1)..<limit]
                let body = Self.fold(rows.joined(separator: " "))
                let title = Self.fold(name + " " + heading.title)
                let score = words.reduce(0) { score, term in
                    score + (title.contains(term) ? 8 : body.contains(term) ? 5 : 0)
                }
                guard score > 0 else { return nil }
                let first = rows.dropFirst().first { row in words.contains(where: Self.fold(row).contains) }
                let excerpt = first ?? rows.dropFirst().first { !$0.isEmpty } ?? ""
                let all = words.allSatisfy { title.contains($0) || body.contains($0) }
                return SearchHit(url: entry.url, line: heading.line, title: heading.title,
                                 excerpt: String(excerpt.prefix(240)), score: score + (all ? 100 : 0))
            }
        }
        return Array(results.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }.prefix(300))
    }

    private static func sorted(_ nodes: [FileNode]) -> [FileNode] {
        nodes.sorted {
            if ($0.children == nil) != ($1.children == nil) { return $0.children != nil }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
