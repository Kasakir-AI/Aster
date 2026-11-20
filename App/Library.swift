import AppKit
import Observation
import QuickLookThumbnailing
import UniformTypeIdentifiers

enum ReadingMode: String, CaseIterable, Identifiable {
    case read = "Read", styled = "Write", source = "Source", split = "Split"
    var id: Self { self }
    var icon: String {
        switch self {
        case .read: "text.alignleft"
        case .styled: "pencil.line"
        case .source: "chevron.left.forwardslash.chevron.right"
        case .split: "rectangle.split.2x1"
        }
    }
}

@MainActor @Observable final class Note: Identifiable {
    let id = UUID()
    var url: URL?
    var text: String
    var saved: String
    var encoding: MarkdownFile.Encoding
    var modified: Date?
    var conflict = false
    var titleOverride: String?
    var title: String { url?.lastPathComponent ?? titleOverride ?? "Untitled Markdown" }
    var dirty: Bool { text != saved }

    init(url: URL? = nil, text: String = "", encoding: MarkdownFile.Encoding = .utf8, title: String? = nil) {
        self.url = url
        self.text = text
        self.saved = text
        self.encoding = encoding
        self.titleOverride = title
        self.modified = url.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
    }
}

@MainActor @Observable final class Library {
    var notes: [Note] = []
    var selection: UUID? {
        didSet { if oldValue != selection { jump = nil } }
    }
    var active: Note? { notes.first { $0.id == selection } }
    var root: URL?
    var index = WorkspaceIndex.empty
    var indexing = false
    var mode: ReadingMode = .read {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "viewMode") }
    }
    var error: String?
    var jump: Jump?
    var sidebar = true
    var inspector = false
    var presented: Sheet?
    var previewSearch = false
    var focusMode = false
    var typewriter = false
    weak var editor: SourceTextView?
    weak var renderer: RenderView?
    private var indexTask: Task<Void, Never>?
    private var pendingIndex: Task<Void, Never>?
    private var pendingSaves: [UUID: Task<Void, Never>] = [:]

    struct Jump: Equatable { let id = UUID(); let line: Int }
    enum Sheet: String, Identifiable { case search, openQuickly, links; var id: Self { self } }

    func newNote() {
        let note = Note()
        notes.append(note)
        selection = note.id
        if mode == .read { mode = .source }
    }

    func open(_ url: URL, line: Int? = nil) {
        if url.scheme == "aster-markdown" { receiveXcode(url); return }
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        if let note = notes.first(where: { $0.url == url }) {
            selection = note.id
        } else {
            do {
                let content = try MarkdownFile.load(url)
                let note = Note(url: url, text: content.text, encoding: content.encoding)
                notes.append(note)
                selection = note.id
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
            } catch {
                self.error = error.localizedDescription
            }
        }
        if let line { go(to: line) }
        persist()
    }

    func chooseDocuments() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [MarkdownFile.type] + MarkdownFile.extensions.compactMap { UTType(filenameExtension: $0) }
        picker.allowsMultipleSelection = true
        guard picker.runModal() == .OK else { return }
        picker.urls.forEach { open($0) }
    }

    func chooseWorkspace() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.prompt = "Open Workspace"
        guard picker.runModal() == .OK, let folder = picker.url else { return }
        openWorkspace(folder)
    }

    func openWorkspace(_ url: URL) {
        root = url.resolvingSymlinksInPath().standardizedFileURL
        sidebar = true
        index = .empty
        refreshIndex()
        persist()
    }

    func refreshIndex() {
        indexTask?.cancel()
        guard let root else { return }
        let unsaved = Dictionary(uniqueKeysWithValues: notes.compactMap { note in
            note.url.map { ($0, note.text) }
        })
        indexing = true
        indexTask = Task { [weak self] in
            let scan = Task.detached(priority: .userInitiated) {
                WorkspaceIndex.scan(root, unsaved: unsaved)
            }
            let result = await withTaskCancellationHandler {
                await scan.value
            } onCancel: {
                scan.cancel()
            }
            guard !Task.isCancelled, let self, self.root == root else { return }
            self.index = result
            self.indexing = false
        }
    }

    @discardableResult func save(_ note: Note? = nil, asNewFile: Bool = false, automatic: Bool = false) -> Bool {
        guard let note = note ?? active else { return false }
        if !asNewFile, let url = note.url {
            guard url.resolvingSymlinksInPath() == url else {
                if !automatic { return save(note, asNewFile: true) }
                return false
            }
            checkDisk(note, readContents: true)
            if note.conflict {
                guard !automatic else { return false }
                let alert = NSAlert()
                alert.messageText = "The file changed on disk"
                alert.informativeText = "Save your changes to a new file, or replace the disk version."
                alert.addButton(withTitle: "Save a Copy")
                alert.addButton(withTitle: "Replace")
                alert.addButton(withTitle: "Cancel")
                switch alert.runModal() {
                case .alertFirstButtonReturn: return save(note, asNewFile: true)
                case .alertSecondButtonReturn: break
                default: return false
                }
            }
            if !note.dirty && !note.conflict { return true }
            return write(note, to: url)
        }
        let picker = NSSavePanel()
        picker.allowedContentTypes = [MarkdownFile.type]
        picker.nameFieldStringValue = note.url?.lastPathComponent ?? "Untitled.md"
        picker.directoryURL = root
        guard picker.runModal() == .OK, let url = picker.url else { return false }
        let destination = url.resolvingSymlinksInPath().standardizedFileURL
        if let source = note.url, destination == source || url.standardizedFileURL == source {
            error = "Choose a different location for the copy."
            return false
        }
        guard !notes.contains(where: { $0 !== note && $0.url == destination }) else {
            error = "That file is already open in another tab."
            return false
        }
        return write(note, to: destination)
    }

    private func write(_ note: Note, to url: URL) -> Bool {
        do {
            guard let data = note.encoding.data(for: note.text) else {
                error = "This document’s text encoding cannot represent one or more characters."
                return false
            }
            try data.write(to: url, options: .atomic)
            note.url = url
            note.saved = note.text
            note.conflict = false
            note.modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            persist()
            refreshIndex()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func close(_ note: Note) {
        guard confirmClose(note), let position = notes.firstIndex(where: { $0 === note }) else { return }
        pendingSaves.removeValue(forKey: note.id)?.cancel()
        notes.remove(at: position)
        if selection == note.id { selection = notes.isEmpty ? nil : notes[min(position, notes.count - 1)].id }
        persist()
    }

    func confirmClose(_ note: Note) -> Bool {
        guard note.dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(note.title)”?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Changes")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(note)
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func checkDisk() {
        for note in notes { checkDisk(note) }
    }

    private func checkDisk(_ note: Note, readContents: Bool = false) {
        guard let url = note.url else { return }
        let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        guard readContents || date != note.modified else { return }
        guard let content = try? MarkdownFile.load(url) else {
            note.conflict = true
            return
        }
        if note.dirty, content.text != note.saved {
            note.conflict = true
        } else {
            if !note.dirty {
                note.text = content.text
                note.saved = content.text
                note.encoding = content.encoding
            }
            note.conflict = false
            note.modified = date
        }
    }

    func go(to line: Int) { jump = Jump(line: line) }

    func moveTab(_ shift: Int) {
        guard !notes.isEmpty, let index = notes.firstIndex(where: { $0.id == selection }) else { return }
        selection = notes[(index + shift + notes.count) % notes.count].id
        persist()
    }

    func cycleMode() {
        let modes = ReadingMode.allCases
        mode = modes[((modes.firstIndex(of: mode) ?? 0) + 1) % modes.count]
    }

    func follow(_ address: String) {
        if let url = URL(string: address), let scheme = url.scheme?.lowercased() {
            if ["http", "https", "mailto"].contains(scheme) { NSWorkspace.shared.open(url) }
            return
        }
        guard let source = active?.url, let target = MarkdownFile.localURL(address, relativeTo: source) else { return }
        if MarkdownFile.isMarkdown(target) {
            open(target)
            if active?.url == target, let fragment = address.split(separator: "#", maxSplits: 1).dropFirst().first,
               let heading = WorkspaceIndex.heading(matching: String(fragment), in: active?.text ?? "") {
                go(to: heading.line)
            }
        } else if FileManager.default.fileExists(atPath: target.path) {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }

    func toggleTask(_ line: Int) {
        guard let note = active, let text = MarkdownFile.toggleTask(at: line, in: note.text) else { return }
        if mode == .split {
            editor?.replaceSource(text)
        } else {
            edit(note, text: text)
        }
    }

    func edit(_ note: Note, text: String) {
        note.text = text
        scheduleIndexRefresh()
        pendingSaves.removeValue(forKey: note.id)?.cancel()
        guard UserDefaults.standard.bool(forKey: "autoSave"), note.url != nil, note.dirty else { return }
        pendingSaves[note.id] = Task { [weak self, weak note] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let self, let note else { return }
            pendingSaves.removeValue(forKey: note.id)
            if UserDefaults.standard.bool(forKey: "autoSave"), note.dirty {
                save(note, automatic: true)
            }
        }
    }

    func restore() {
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: "viewMode"), let previous = ReadingMode(rawValue: value) { mode = previous }
        guard defaults.object(forKey: "restoreSession") as? Bool ?? true else { return }
        if let folder = defaults.url(forKey: "workspace"), FileManager.default.fileExists(atPath: folder.path) {
            root = folder.standardizedFileURL
        }
        let paths = defaults.stringArray(forKey: "openDocuments") ?? []
        let selectedPath = defaults.string(forKey: "selectedDocument")
        for path in paths where FileManager.default.fileExists(atPath: path) { open(URL(fileURLWithPath: path)) }
        if let selectedPath, let note = notes.first(where: { $0.url?.path == selectedPath }) { selection = note.id }
        refreshIndex()
        persist()
    }

    func persist() {
        let defaults = UserDefaults.standard
        defaults.set(root, forKey: "workspace")
        defaults.set(notes.compactMap { $0.url?.path }, forKey: "openDocuments")
        defaults.set(active?.url?.path, forKey: "selectedDocument")
    }

    private func scheduleIndexRefresh() {
        pendingIndex?.cancel()
        pendingIndex = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            refreshIndex()
        }
    }

    private func receiveXcode(_ url: URL) {
        guard let source = PreviewTransfer.source(from: url) else { return }
        if let note = notes.first(where: { $0.url == nil && $0.titleOverride == "Xcode Preview" }) {
            note.text = source
            note.saved = source
            note.conflict = false
            selection = note.id
        } else {
            let note = Note(text: source, title: "Xcode Preview")
            notes.append(note)
            selection = note.id
        }
        let remembered = UserDefaults.standard.object(forKey: "viewMode")
        if mode == .source || mode == .styled { mode = .read }
        UserDefaults.standard.set(remembered, forKey: "viewMode")
    }
}
