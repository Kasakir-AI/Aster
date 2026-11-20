import SwiftUI

struct WorkspacePanel: View {
    let model: Library
    let panel: Library.Sheet
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var mode = SearchMode.sections
    @State private var hits: [SearchHit] = []
    @State private var error: String?
    @State private var selectedFile: URL?
    @State private var selectedHit: String?
    @State private var graphSelection: URL?
    @FocusState private var focused: Bool

    private var title: String {
        switch panel {
        case .search: "Search Workspace"
        case .openQuickly: "Open Quickly"
        case .links: "Link Map"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(title).font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if panel == .links {
                linkMap
            } else {
                TextField(panel == .search ? "Search Markdown" : "Type a filename", text: $query)
                    .textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit(openSelected)
                    .onMoveCommand(perform: moveSelection)
                if panel == .search { searchResults } else { fileResults }
            }
        }
        .padding(19)
        .frame(width: panel == .links ? 740 : 590, height: panel == .links ? 565 : 440)
        .onAppear { focused = true }
        .task(id: SearchRequest(query: query, mode: mode)) { await updateSearch() }
    }

    private struct SearchRequest: Equatable { let query: String; let mode: SearchMode }

    private var files: [URL] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return model.index.entries.map(\.url).filter { url in
            terms.allSatisfy { url.lastPathComponent.localizedStandardContains($0) || path(url).localizedStandardContains($0) }
        }
    }

    private var fileResults: some View {
        List(selection: $selectedFile) {
            ForEach(files, id: \.self) { url in
                HStack {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                    Text(url.lastPathComponent)
                    Spacer()
                    Text(path(url)).foregroundStyle(.secondary).font(.caption).lineLimit(1).truncationMode(.middle)
                }
                .tag(url)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { open(url) }
            }
        }
        .onChange(of: query, initial: true) { _, _ in selectedFile = files.first }
        .overlay { if files.isEmpty { Text("No matching files").foregroundStyle(.secondary) } }
    }

    private var searchResults: some View {
        VStack(alignment: .leading) {
            Picker("Search mode", selection: $mode) {
                ForEach(SearchMode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            List(selection: $selectedHit) {
                ForEach(hits) { hit in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(hit.title).fontWeight(.medium).lineLimit(1)
                            Spacer()
                            Text(path(hit.url) + " · " + String(hit.line)).font(.caption).foregroundStyle(.secondary)
                        }
                        if !hit.excerpt.isEmpty { Text(hit.excerpt).lineLimit(2).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 3).tag(hit.id).contentShape(Rectangle())
                    .onTapGesture(count: 2) { open(hit.url, line: hit.line) }
                }
            }
            .overlay {
                if hits.isEmpty && error == nil {
                    Text(query.isEmpty ? "Search headings and text across the workspace." : "No matches")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var linkMap: some View {
        let links = model.index.links
        let broken = links.filter(\.broken)
        let connected = Set(links.flatMap { $0.broken ? [$0.source] : [$0.source, $0.target] })
        let nodes = connected.sorted(by: { $0.path < $1.path })
        let focus = graphSelection
        return VStack(alignment: .leading, spacing: 8) {
            if nodes.isEmpty {
                ContentUnavailableView("No document links", systemImage: "point.3.connected.trianglepath.dotted")
            } else {
                HStack {
                    Picker("Show connections for", selection: $graphSelection) {
                        Text("All linked documents").tag(URL?.none)
                        ForEach(nodes, id: \.self) { url in Text(path(url)).tag(Optional(url)) }
                    }.frame(maxWidth: 440)
                    Spacer()
                    Text("\(links.count) links").foregroundStyle(.secondary)
                }
                let visibleLinks = links.filter { !$0.broken && (focus == nil || $0.source == focus || $0.target == focus) }
                let visibleNodes = focus.map { Set([$0] + visibleLinks.flatMap { [$0.source, $0.target] }).sorted(by: { $0.path < $1.path }) } ?? nodes
                Graph(nodes: Array(visibleNodes.prefix(32)), links: visibleLinks, center: focus) { open($0) }
                    .frame(minHeight: 235)
                if visibleNodes.count > 32 {
                    Text("Showing 32 documents. Choose a file to see its connections.").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                if broken.isEmpty {
                    Label("No broken links", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else {
                    Text("\(broken.count) broken \(broken.count == 1 ? "link" : "links")").font(.headline)
                    List(broken) { link in
                        Button {
                            open(link.source)
                        } label: {
                            HStack {
                                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                                Text(path(link.source))
                                Image(systemName: "arrow.right").font(.caption)
                                Text(link.address).foregroundStyle(.secondary)
                            }.lineLimit(1)
                        }.buttonStyle(.plain)
                    }.frame(minHeight: 58, maxHeight: 138)
                }
            }
        }
    }

    private func path(_ url: URL) -> String {
        guard let root = model.root, url.path.hasPrefix(root.path + "/") else { return url.lastPathComponent }
        return String(url.path.dropFirst(root.path.count + 1))
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard direction == .down || direction == .up else { return }
        let offset = direction == .down ? 1 : -1
        if panel == .search {
            let ids = hits.map(\.id)
            if let index = ids.firstIndex(where: { $0 == selectedHit }) {
                selectedHit = ids[min(max(0, index + offset), ids.count - 1)]
            } else {
                selectedHit = ids.first
            }
        } else {
            let urls = files
            if let index = urls.firstIndex(where: { $0 == selectedFile }) {
                selectedFile = urls[min(max(0, index + offset), urls.count - 1)]
            } else {
                selectedFile = urls.first
            }
        }
    }

    private func openSelected() {
        if panel == .search, let hit = hits.first(where: { $0.id == selectedHit }) { open(hit.url, line: hit.line) }
        if panel == .openQuickly, let selectedFile { open(selectedFile) }
    }

    private func open(_ url: URL, line: Int? = nil) {
        model.open(url, line: line)
        dismiss()
    }

    private func updateSearch() async {
        guard panel == .search else { return }
        let text = query
        let mode = mode
        let index = model.index
        try? await Task.sleep(for: .milliseconds(140))
        guard !Task.isCancelled else { return }
        let result = await Task.detached { Result { try index.search(text, mode: mode) } }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let found):
            hits = found
            error = nil
            selectedHit = found.first?.id
        case .failure:
            hits = []
            error = "Enter a valid regular expression."
        }
    }
}

private struct Graph: View {
    let nodes: [URL]
    let links: [DocumentLink]
    let center: URL?
    let open: (URL) -> Void

    var body: some View {
        GeometryReader { layout in
            let middle = CGPoint(x: layout.size.width / 2, y: layout.size.height / 2)
            let orbit = nodes.filter { $0 != center }
            let positions = Dictionary(uniqueKeysWithValues: nodes.map { url -> (URL, CGPoint) in
                guard let index = orbit.firstIndex(of: url) else { return (url, middle) }
                let stagger = orbit.count > 10 && index.isMultiple(of: 2) ? 0.65 : 1.0
                let angle = (Double(index) / Double(orbit.count)) * 2 * .pi - .pi / 2
                return (url, CGPoint(x: middle.x + cos(angle) * max(10, middle.x - 65) * stagger,
                                     y: middle.y + sin(angle) * max(10, middle.y - 26) * stagger))
            })
            Canvas { context, _ in
                for link in links {
                    guard let from = positions[link.source], let to = positions[link.target], from != to else { continue }
                    var line = Path()
                    line.move(to: from)
                    line.addLine(to: to)
                    context.stroke(line, with: .color(.purple.opacity(0.33)), lineWidth: 1)
                }
            }.accessibilityHidden(true)
            ForEach(nodes, id: \.self) { url in
                if let point = positions[url] {
                    Button { open(url) } label: {
                        Text(url.deletingPathExtension().lastPathComponent)
                            .font(.caption).lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.purple.opacity(0.5)))
                    }.buttonStyle(.plain).help(url.path).frame(maxWidth: 105).position(point)
                }
            }
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
