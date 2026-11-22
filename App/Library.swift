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
        didSet {
            if oldValue != selection { jump = nil }
            applyDocumentMode()
        }
    }
    var active: Note? { notes.first { $0.id == selection } }
    var root: URL?
    var index = WorkspaceIndex.empty
    var indexing = false
    var mode: ReadingMode = .read {
        didSet { rememberMode() }
    }
    private var suppressModeSave = false
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
    private let scopes = FolderAccess.Scopes()
    private var bookmarked: Set<URL> = []

    struct Jump: Equatable { let id = UUID(); let line: Int }
    enum Sheet: String, Identifiable { case search, openQuickly, links; var id: Self { self } }

    func newNote() {
        let note = Note()
        notes.append(note)
        selection = note.id
        if mode == .read { showMode(.source) }
    }

    func open(_ url: URL, line: Int? = nil) {
        if url.scheme == "aster-markdown" { receiveXcode(url); return }
        guard url.isFileURL else { return }
        let url = grant(url)
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
                return
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
        guard url.isFileURL else { return }
        root = grant(url)
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
            return saveExisting(note, at: url, automatic: automatic)
        }
        let picker = NSSavePanel()
        picker.allowedContentTypes = [MarkdownFile.type]
        picker.nameFieldStringValue = note.url?.lastPathComponent ?? "Untitled.md"
        picker.directoryURL = root
        guard picker.runModal() == .OK, let url = picker.url else { return false }
        let destination = grant(url)
        if let source = note.url, destination == source || url.standardizedFileURL == source {
            error = "Choose a different location for the copy."
            return false
        }
        guard !notes.contains(where: { $0 !== note && $0.url == destination }) else {
            error = "That file is already open in another tab."
            return false
        }
        do {
            let data = try encodedContents(of: note)
            let modified = try coordinateWrite(at: destination, options: .forReplacing) { file in
                guard file.path == destination.path, file.resolvingSymlinksInPath().path == file.path else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "The save location changed. Choose the location again."])
                }
                try data.write(to: file, options: .atomic)
                return Self.modificationDate(at: file)
            }
            grant(url)
            didSave(note, at: destination, modified: modified)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private struct DiskVersion: Equatable {
        let text: String?
        let encoding: MarkdownFile.Encoding?
        let modified: Date?
        let size: Int?

        init(at url: URL) {
            let file = URL(fileURLWithPath: url.path)
            let content = try? MarkdownFile.load(file)
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            text = content?.text
            encoding = content?.encoding
            modified = values?.contentModificationDate
            size = values?.fileSize
        }
    }

    private enum SaveResult {
        case unchanged(DiskVersion)
        case written(Date?)
        case conflict(DiskVersion)
        case moved
    }

    private func saveExisting(_ note: Note, at url: URL, automatic: Bool) -> Bool {
        var versionToReplace: DiskVersion?
        do {
            while note.url == url {
                guard url.resolvingSymlinksInPath().path == url.path else {
                    note.conflict = true
                    return automatic ? false : save(note, asNewFile: true)
                }
                let payload = note.dirty || versionToReplace != nil ? Result { try encodedContents(of: note) } : nil
                let result: SaveResult = try coordinateWrite(at: url, options: []) { file in
                    guard file.path == url.path, url.resolvingSymlinksInPath().path == url.path else { return .moved }
                    let disk = DiskVersion(at: file)
                    if let versionToReplace {
                        guard disk == versionToReplace else { return .conflict(disk) }
                    } else if conflicts(note, with: disk) {
                        return .conflict(disk)
                    }
                    guard let payload else { return .unchanged(disk) }
                    try payload.get().write(to: file, options: .atomic)
                    return .written(Self.modificationDate(at: file))
                }

                switch result {
                case .unchanged(let disk):
                    apply(disk, to: note)
                    return true
                case .written(let modified):
                    didSave(note, at: url, modified: modified)
                    return true
                case .moved:
                    note.conflict = true
                    return automatic ? false : save(note, asNewFile: true)
                case .conflict(let disk):
                    note.conflict = true
                    guard !automatic else { return false }
                    let alert = NSAlert()
                    alert.messageText = versionToReplace == nil ? "The file changed on disk" : "The file changed again on disk"
                    alert.informativeText = "Save your changes to a new file, or replace the disk version."
                    alert.addButton(withTitle: "Save a Copy")
                    alert.addButton(withTitle: "Replace")
                    alert.addButton(withTitle: "Cancel")
                    switch alert.runModal() {
                    case .alertFirstButtonReturn: return save(note, asNewFile: true)
                    case .alertSecondButtonReturn: versionToReplace = disk
                    default: return false
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
        return false
    }

    private func coordinateWrite<Value>(at url: URL, options: NSFileCoordinator.WritingOptions,
                                        _ body: (URL) throws -> Value) throws -> Value {
        var coordinationError: NSError?
        var result: Result<Value, Error> = .failure(CocoaError(.fileWriteUnknown))
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &coordinationError) { file in
            result = Result { try body(file) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    private func encodedContents(of note: Note) throws -> Data {
        guard let data = note.encoding.data(for: note.text) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding, userInfo: [
                NSLocalizedDescriptionKey: "This document’s text encoding cannot represent one or more characters."
            ])
        }
        guard data.count <= MarkdownFile.maximumBytes else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "Aster can save Markdown files up to 12 MB. Your changes are still in this tab."
            ])
        }
        return data
    }

    private func didSave(_ note: Note, at url: URL, modified: Date?) {
        note.url = url
        note.saved = note.text
        note.conflict = false
        note.modified = modified
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        persist()
        refreshIndex()
    }

    private static func modificationDate(at url: URL) -> Date? {
        try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
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

    private func checkDisk(_ note: Note) {
        guard let url = note.url else { return }
        guard url.resolvingSymlinksInPath().path == url.path else {
            note.conflict = true
            return
        }
        guard Self.modificationDate(at: url) != note.modified else { return }
        apply(DiskVersion(at: url), to: note)
    }

    private func conflicts(_ note: Note, with disk: DiskVersion) -> Bool {
        disk.text == nil || (note.dirty && (disk.text != note.saved || disk.encoding != note.encoding))
    }

    private func apply(_ disk: DiskVersion, to note: Note) {
        note.conflict = conflicts(note, with: disk)
        if !note.conflict, !note.dirty, let text = disk.text, let encoding = disk.encoding {
            note.text = text
            note.saved = text
            note.encoding = encoding
        }
        if !note.conflict { note.modified = disk.modified }
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

    func copyCode(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    func follow(_ address: String) {
        if let source = active?.url, let match = WorkspaceIndex.wikiMatch(address, among: wikiNotes(near: source), near: source) {
            guard canFollowLocalLink(match.url, from: source) else { return }
            open(match.url)
            if active?.url == match.url, let heading = match.heading,
               let found = WorkspaceIndex.heading(matching: heading, in: active?.text ?? "") {
                go(to: found.line)
            }
            return
        }
        if let url = URL(string: address), let scheme = url.scheme?.lowercased() {
            if ["http", "https", "mailto"].contains(scheme) { NSWorkspace.shared.open(url) }
            return
        }
        guard let source = active?.url, let target = MarkdownFile.localURL(address, relativeTo: source) else { return }
        guard canFollowLocalLink(target, from: source) else { return }
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

    func canFollowLocalLink(_ target: URL, from source: URL) -> Bool {
        !UserDefaults.standard.bool(forKey: StoredSettings.workspaceLinksOnly)
            || FolderAccess.linkStaysInside(target, workspace: root, document: source)
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
        guard UserDefaults.standard.bool(forKey: StoredSettings.autoSave), note.url != nil, note.dirty else { return }
        pendingSaves[note.id] = Task { [weak self, weak note] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let self, let note else { return }
            pendingSaves.removeValue(forKey: note.id)
            if UserDefaults.standard.bool(forKey: StoredSettings.autoSave), note.dirty {
                save(note, automatic: true)
            }
        }
    }

    func restore() {
        let defaults = UserDefaults.standard
        let reopen = defaults.object(forKey: StoredSettings.restoreSession) as? Bool ?? true
        let locations = restoreAccess(refreshStale: reopen)
        if let value = defaults.string(forKey: StoredSettings.viewMode), let previous = ReadingMode(rawValue: value) { mode = previous }
        guard reopen else { return }
        let previousRoot = defaults.url(forKey: StoredSettings.workspace)
        if let folder = previousRoot {
            let restored = locations[folder.path] ?? folder
            if FileManager.default.fileExists(atPath: restored.path) { root = restored.standardizedFileURL }
        }

        func restoredURL(for path: String) -> URL {
            if let restored = locations[path] { return restored }
            if let previousRoot, let root, previousRoot != root {
                let prefix = previousRoot.path + "/"
                if path.hasPrefix(prefix) {
                    return root.appending(path: String(path.dropFirst(prefix.count))).standardizedFileURL
                }
            }
            return URL(fileURLWithPath: path)
        }

        let paths = defaults.stringArray(forKey: StoredSettings.openDocuments) ?? []
        let selectedPath = defaults.string(forKey: StoredSettings.selectedDocument)
        for url in paths.map(restoredURL(for:)) where FileManager.default.fileExists(atPath: url.path) { open(url) }
        if let selectedPath, let note = notes.first(where: { $0.url == restoredURL(for: selectedPath) }) {
            selection = note.id
        }
        refreshIndex()
        persist()
    }

    func persist() {
        let defaults = UserDefaults.standard
        defaults.set(root, forKey: StoredSettings.workspace)
        defaults.set(notes.compactMap { $0.url?.path }, forKey: StoredSettings.openDocuments)
        defaults.set(active?.url?.path, forKey: StoredSettings.selectedDocument)
    }

    private func wikiNotes(near document: URL) -> [URL] {
        if !index.entries.isEmpty { return index.entries.map(\.url) }
        let folder = document.deletingLastPathComponent()
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { MarkdownFile.isMarkdown($0) }
    }

    private func rememberMode() {
        guard !suppressModeSave else { return }
        if let path = active?.url?.path {
            let stored = UserDefaults.standard.object(forKey: StoredSettings.documentViewModes) as? [String: String] ?? [:]
            UserDefaults.standard.set(DocumentModes.remembering(mode.rawValue, for: path, in: stored), forKey: StoredSettings.documentViewModes)
        } else {
            UserDefaults.standard.set(mode.rawValue, forKey: StoredSettings.viewMode)
        }
    }

    private func applyDocumentMode() {
        guard let path = active?.url?.path else { return }
        let stored = UserDefaults.standard.object(forKey: StoredSettings.documentViewModes) as? [String: String] ?? [:]
        let fallback = UserDefaults.standard.string(forKey: StoredSettings.viewMode).flatMap(ReadingMode.init(rawValue:)) ?? .read
        let saved = DocumentModes.raw(for: path, in: stored).flatMap(ReadingMode.init(rawValue:)) ?? fallback
        showMode(saved)
    }

    private func showMode(_ mode: ReadingMode) {
        guard mode != self.mode else { return }
        suppressModeSave = true
        self.mode = mode
        suppressModeSave = false
    }

    private func restoreAccess(refreshStale: Bool) -> [String: URL] {
        let defaults = UserDefaults.standard
        let blobs = defaults.array(forKey: StoredSettings.folderBookmarks) as? [Data] ?? []
        var locations: [String: URL] = [:]
        let refreshed = blobs.map { data in
            guard let resolved = FolderAccess.resolve(data) else { return data }
            let canonical = scopes.retain(resolved.url)
            bookmarked.insert(canonical)
            if let path = FolderAccess.previousPath(of: data) { locations[path] = canonical }
            if refreshStale, resolved.stale, let replacement = FolderAccess.bookmark(for: resolved.url) { return replacement }
            return data
        }
        if refreshed != blobs { defaults.set(refreshed, forKey: StoredSettings.folderBookmarks) }
        return locations
    }

    @discardableResult
    private func grant(_ url: URL) -> URL {
        let canonical = scopes.retain(url)
        guard !bookmarked.contains(where: { FolderAccess.contains(canonical, in: $0) }),
              let data = FolderAccess.bookmark(for: url) else { return canonical }
        bookmarked.insert(canonical)
        let defaults = UserDefaults.standard
        var blobs = defaults.array(forKey: StoredSettings.folderBookmarks) as? [Data] ?? []
        blobs.append(data)
        defaults.set(blobs, forKey: StoredSettings.folderBookmarks)
        return canonical
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
        if let note = notes.first(where: { $0.url == nil && $0.titleOverride == "Xcode Preview" && !$0.dirty }) {
            note.text = source
            note.saved = source
            note.conflict = false
            selection = note.id
        } else {
            let note = Note(text: source, title: "Xcode Preview")
            notes.append(note)
            selection = note.id
        }
        if mode == .source || mode == .styled { showMode(.read) }
    }
}
