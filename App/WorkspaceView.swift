import SwiftUI
import NaturalLanguage
import WebKit

struct WorkspaceView: View {
    @Bindable var model: Library
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("fontSize") private var fontSize = 16.0
    @AppStorage("mermaid") private var mermaid = true
    @AppStorage("math") private var math = true
    @AppStorage("frontMatter") private var frontMatter = true
    @State private var previewQuery = ""
    @State private var dropping = false

    private var palette: AsterPalette { colorScheme == .dark ? .dark : .light }
    private var lilac: Color { Color(nsColor: palette.heading) }

    var body: some View {
        HSplitView {
            if model.sidebar { sidebar.frame(minWidth: 175, idealWidth: 230, maxWidth: 385) }
            VStack(spacing: 0) {
                if !model.notes.isEmpty { tabBar }
                if let note = model.active {
                    if model.previewSearch && model.mode == .read { findBar }
                    if note.conflict { conflictBar }
                    content(note).id(note.id)
                    status(note)
                } else { welcome }
            }
            .frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
            if model.inspector, let note = model.active {
                inspector(note).frame(minWidth: 160, idealWidth: 210, maxWidth: 295)
            }
        }
        .frame(minWidth: 690, minHeight: 425)
        .background(Color(nsColor: palette.page))
        .tint(lilac)
        .navigationTitle(model.active?.title ?? "Aster")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.sidebar.toggle() } label: { Label("Workspace", systemImage: "sidebar.left") }
                    .help("Show or hide the workspace")
            }
            ToolbarItemGroup {
                Button { model.presented = .openQuickly } label: { Label("Open Quickly", systemImage: "command") }
                    .disabled(model.root == nil)
                Button { model.presented = .search } label: { Label("Search Workspace", systemImage: "magnifyingglass") }
                    .disabled(model.root == nil)
                Picker("View mode", selection: $model.mode) {
                    ForEach(ReadingMode.allCases) { mode in
                        Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                            .help(mode.rawValue)
                    }
                }.pickerStyle(.segmented).labelsHidden().disabled(model.active == nil)
                Button { model.inspector.toggle() } label: { Label("Outline", systemImage: "sidebar.right") }
                    .disabled(model.active == nil)
            }
        }
        .sheet(item: $model.presented) { panel in WorkspacePanel(model: model, panel: panel) }
        .alert("Aster", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .dropDestination(for: URL.self) { urls, _ in
            var opened = false
            for url in urls where url.isFileURL {
                if MarkdownFile.isMarkdown(url) { model.open(url); opened = true }
                else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    model.openWorkspace(url)
                    opened = true
                }
            }
            return opened
        } isTargeted: { dropping = $0 }
        .overlay { if dropping { RoundedRectangle(cornerRadius: 7).strokeBorder(lilac, lineWidth: 2).allowsHitTesting(false) } }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { break }
                model.checkDisk()
            }
        }

    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text("✱").font(.system(size: 17, weight: .semibold)).foregroundStyle(lilac)
                    .accessibilityHidden(true)
                Text(model.root?.lastPathComponent ?? "Workspace")
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Button { model.chooseWorkspace() } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.plain).help("Open Workspace")
                if model.root != nil {
                    Button { model.refreshIndex() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("Refresh Workspace")
                }
            }.padding(.horizontal, 14).padding(.vertical, 12)
            Divider()
            if model.root == nil {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Browse a folder of Markdown files.").font(.callout).foregroundStyle(.secondary)
                    Button("Open Workspace…") { model.chooseWorkspace() }
                }.padding(15)
            } else if model.indexing && model.index.tree.isEmpty {
                ProgressView().controlSize(.small).padding(16)
            } else if model.index.tree.isEmpty {
                Text("No Markdown files in this folder").font(.callout).foregroundStyle(.secondary).padding(15)
            } else {
                List(model.index.tree, children: \.children) { node in
                    if node.children != nil {
                        Label(node.url.lastPathComponent, systemImage: "folder")
                            .foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Button { model.open(node.url) } label: {
                            Label(node.url.lastPathComponent, systemImage: "doc.text")
                                .lineLimit(1)
                                .foregroundStyle(model.active?.url == node.url ? .primary : .secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(model.active?.url == node.url ? lilac.opacity(0.20) : .clear)
                        .contextMenu {
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
                            Button("Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(node.url.path, forType: .string)
                            }
                        }
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
            }
            Spacer(minLength: 0)
            if model.root != nil {
                Divider()
                Button { model.presented = .links } label: { Label("Link Map", systemImage: "point.3.connected.trianglepath.dotted") }
                    .buttonStyle(.plain).padding(12)
            }
        }.background(.regularMaterial)
    }

    private var tabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(model.notes) { note in
                        HStack(spacing: 7) {
                            Button {
                                model.selection = note.id
                                model.persist()
                            } label: {
                                HStack(spacing: 6) {
                                    if note.dirty { Circle().fill(lilac).frame(width: 6, height: 6).accessibilityLabel("Unsaved") }
                                    Text(note.title).lineLimit(1).truncationMode(.middle)
                                }.frame(maxWidth: model.selection == note.id ? 230 : 130)
                            }.buttonStyle(.plain)
                            Button { model.close(note) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Close \(note.title)")
                        }
                        .font(.system(size: 12, weight: model.selection == note.id ? .semibold : .regular))
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(model.selection == note.id ? lilac.opacity(0.23) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .id(note.id).help(note.url?.path ?? note.title)
                    }
                    Button { model.newNote() } label: { Image(systemName: "plus").font(.system(size: 12, weight: .medium)) }
                        .buttonStyle(.plain).help("New Markdown Document").padding(.horizontal, 7)
                }.padding(.horizontal, 8).padding(.vertical, 5)
            }
            .onChange(of: model.selection) { _, selection in
                if let selection { proxy.scrollTo(selection) }
            }
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder private func content(_ note: Note) -> some View {
        let options = RenderOptions(interactive: true, appearance: colorScheme == .dark ? .dark : .light, fontSize: fontSize,
                                    diagrams: mermaid, math: math, metadata: frontMatter)
        switch model.mode {
        case .read:
            PreviewPane(note: note, model: model, options: options)
        case .source, .styled:
            SourceEditor(note: note, model: model, fontSize: fontSize - 2, jump: model.jump)
        case .split:
            HSplitView {
                SourceEditor(note: note, model: model, fontSize: fontSize - 2, jump: model.jump)
                    .frame(minWidth: 210)
                PreviewPane(note: note, model: model, options: options)
                    .frame(minWidth: 210)
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Text("✱").font(.system(size: 69, weight: .medium)).foregroundStyle(lilac).accessibilityHidden(true)
            Text("Aster").font(.system(size: 36, weight: .medium, design: .serif))
            HStack(spacing: 10) {
                Button("Open Markdown…") { model.chooseDocuments() }.buttonStyle(.borderedProminent)
                Button("New Document") { model.newNote() }
            }.controlSize(.large)
            Text("Drop a Markdown file or folder here.").font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var findBar: some View {
        HStack {
            TextField("Find in preview", text: $previewQuery).onSubmit { model.renderer?.find(previewQuery, backwards: false) }
            Button { model.renderer?.find(previewQuery, backwards: true) } label: { Image(systemName: "chevron.up") }
                .help("Previous Match")
            Button { model.renderer?.find(previewQuery, backwards: false) } label: { Image(systemName: "chevron.down") }
                .help("Next Match")
            Button("Done") { model.previewSearch = false }
        }.padding(.horizontal, 12).padding(.vertical, 5)
    }

    private var conflictBar: some View {
        Label("The file changed on disk. Save to review your options.", systemImage: "exclamationmark.triangle")
            .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            .padding(8).background(.orange.opacity(0.15))
    }

    private func inspector(_ note: Note) -> some View {
        let headings = WorkspaceIndex.headings(in: note.text)
        let inbound = model.index.links.filter { $0.target == note.url }
        return VStack(alignment: .leading, spacing: 0) {
            Text("Outline").font(.headline).padding(12)
            Divider()
            List {
                if headings.isEmpty { Text("No headings").foregroundStyle(.secondary) }
                ForEach(headings) { heading in
                    Button { model.go(to: heading.line) } label: {
                        Text(heading.title).lineLimit(2).padding(.leading, CGFloat(heading.level - 1) * 9)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                if !inbound.isEmpty {
                    Section("Backlinks") {
                        ForEach(inbound) { link in
                            Button(link.source.lastPathComponent) { model.open(link.source) }.buttonStyle(.plain)
                        }
                    }
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
        }.background(.regularMaterial)
    }

    private func wordCount(_ text: String, tokenizer: NLTokenizer) -> Int {
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).count
    }

    private func status(_ note: Note) -> some View {
        HStack(spacing: 12) {
            if let url = note.url {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Label(url.deletingLastPathComponent().lastPathComponent, systemImage: "folder")
                }.buttonStyle(.plain).help(url.path).lineLimit(1)
            }
            Spacer()
            if note.dirty { Text("Unsaved") }
            let tokenizer = NLTokenizer(unit: .word)
            let count = wordCount(note.text, tokenizer: tokenizer)
            let lines = note.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
            Text("\(count) words")
            Text("\(lines) lines")
            Text("\(note.text.count) characters")
        }
        .font(.system(size: 11)).monospacedDigit()
        .foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 25)
        .background(.bar).overlay(alignment: .top) { Divider() }
    }
}

private struct PreviewPane: NSViewControllerRepresentable {
    let note: Note
    let model: Library
    let options: RenderOptions

    final class Coordinator {
        var lastJump: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSViewController(context: Context) -> RenderView {
        RenderView()
    }

    func updateNSViewController(_ renderer: RenderView, context: Context) {
        renderer.receive = { [weak model] kind, value in
            guard let model else { return }
            switch (kind, value) {
            case ("scroll", let value as Double) where model.mode == .split: model.editor?.scroll(to: value)
            case ("task", let line as Int): model.toggleTask(line)
            case ("line", let line as Int):
                if model.mode == .read { model.mode = .split }
                model.go(to: line)
            case ("link", let address as String): model.follow(address)
            default: break
            }
        }
        let workspace = model.root.flatMap { root in
            note.url?.path.hasPrefix(root.path + "/") == true ? root : nil
        }
        renderer.update(note.text, url: note.url, directory: workspace ?? note.url?.deletingLastPathComponent(), options: options)
        if let jump = model.jump, context.coordinator.lastJump != jump.id {
            context.coordinator.lastJump = jump.id
            renderer.jump(to: jump.line)
        }
        DispatchQueue.main.async { [weak model, weak renderer] in
            if let renderer, renderer.view.window != nil { model?.renderer = renderer }
        }
    }
}
