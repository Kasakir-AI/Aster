import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main struct AsterApp: App {
    @NSApplicationDelegateAdaptor(AsterDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    @AppStorage("appearance") private var appearance = AsterAppearance.initial

    var body: some Scene {
        Window("Aster", id: "workspace") {
            WorkspaceView(model: delegate.library)
                .preferredColorScheme(appearance.colorScheme)
                .onAppear { delegate.showWindow = { openWindow(id: "workspace") } }
        }
        .defaultSize(width: 1080, height: 730)
        .commands { AsterCommands(model: delegate.library) }
        Settings {
            AsterSettings(appearance: $appearance)
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}

private extension AsterAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}

@MainActor final class AsterDelegate: NSObject, NSApplicationDelegate {
    let library = Library()
    var showWindow: (() -> Void)?
    private var pending: [URL] = []
    private var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        library.restore()
        launched = true
        if !pending.isEmpty {
            open(pending)
            pending.removeAll()
        }
        MarkdownDefault.askIfNeeded()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if launched { open(urls) } else { pending += urls }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showWindow?() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for note in library.notes where !library.confirmClose(note) { return .terminateCancel }
        return .terminateNow
    }

    private func open(_ urls: [URL]) {
        showWindow?()
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                library.openWorkspace(url)
            } else {
                library.open(url)
            }
        }
    }
}

private struct AsterCommands: Commands {
    let model: Library

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Markdown Document") { model.newNote() }.keyboardShortcut("n")
            Button("Open…") { model.chooseDocuments() }.keyboardShortcut("o")
            Button("Open Workspace…") { model.chooseWorkspace() }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Open Quickly…") { model.presented = .openQuickly }.keyboardShortcut("t")
                .disabled(model.root == nil)
            Menu("Open Recent") {
                let recent = NSDocumentController.shared.recentDocumentURLs
                ForEach(recent, id: \.self) { url in Button(url.lastPathComponent) { model.open(url) } }
                Divider()
                Button("Clear Menu") { NSDocumentController.shared.clearRecentDocuments(nil) }.disabled(recent.isEmpty)
            }
            Divider()
            Button("Close Document") { if let note = model.active { model.close(note) } }
                .keyboardShortcut("w").disabled(model.active == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.save() }.keyboardShortcut("s").disabled(model.active == nil)
            Button("Save As…") { model.save(asNewFile: true) }.keyboardShortcut("s", modifiers: [.command, .shift, .option])
                .disabled(model.active == nil)
            Divider()
            Button("Export HTML…") { export(pdf: false) }.disabled(model.active == nil || model.mode == .source || model.mode == .styled)
            Button("Export PDF…") { export(pdf: true) }.keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.active == nil || model.mode == .source || model.mode == .styled)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { model.renderer?.printDocument() }.keyboardShortcut("p")
                .disabled(model.active == nil || model.mode == .source || model.mode == .styled)
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") {
                if model.mode == .read { model.previewSearch = true } else { model.editor?.find(.showFindInterface) }
            }.keyboardShortcut("f").disabled(model.active == nil)
            Button("Find and Replace…") { model.editor?.find(.showReplaceInterface) }
                .keyboardShortcut("f", modifiers: [.command, .option]).disabled(model.mode == .read || model.active == nil)
            Button("Search Workspace…") { model.presented = .search }
                .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(model.root == nil)
        }
        CommandMenu("Format") {
            Button("Bold") { model.editor?.wrap(with: "**") }.keyboardShortcut("b").disabled(!canFormat)
            Button("Italic") { model.editor?.wrap(with: "*") }.keyboardShortcut("i").disabled(!canFormat)
            Button("Link") { model.editor?.wrap(with: "[", suffix: "](https://example.com)", placeholder: "link text") }
                .keyboardShortcut("k").disabled(!canFormat)
            Button("Inline Code") { model.editor?.wrap(with: "`") }
                .keyboardShortcut("`", modifiers: [.command, .option]).disabled(!canFormat)
        }
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Cycle View Mode") { model.cycleMode() }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button(model.sidebar ? "Hide Workspace" : "Show Workspace") { model.sidebar.toggle() }
            Button(model.inspector ? "Hide Outline" : "Show Outline") { model.inspector.toggle() }
            Button("Link Map…") { model.presented = .links }.keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model.root == nil)
            Divider()
            Toggle("Focus Mode", isOn: Bindable(model).focusMode).keyboardShortcut("d", modifiers: [.command, .shift])
            Toggle("Typewriter Mode", isOn: Bindable(model).typewriter).keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("Next Document") { model.moveTab(1) }.keyboardShortcut(.tab, modifiers: [.control])
            Button("Previous Document") { model.moveTab(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
        }
    }

    private var canFormat: Bool { model.mode != .read && model.active != nil }

    private func export(pdf: Bool) {
        guard let note = model.active, let renderer = model.renderer else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = pdf ? [.pdf] : [.html]
        let name = note.url?.deletingPathExtension().lastPathComponent ?? "Untitled"
        panel.nameFieldStringValue = name + (pdf ? ".pdf" : ".html")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { @MainActor in
            do {
                if pdf {
                    let data = try await renderer.makePDF()
                    try data.write(to: destination, options: .atomic)
                } else {
                    let html = try await renderer.html()
                    try html.write(to: destination, atomically: true, encoding: .utf8)
                }
            } catch {
                model.error = error.localizedDescription
            }
        }
    }
}

enum MarkdownDefault {
    private static let askedKey = "didAskMarkdownDefault"

    static var contentTypes: [UTType] {
        var seen: Set<String> = []
        var types: [UTType] = []
        func add(_ type: UTType?) {
            guard let type, seen.insert(type.identifier).inserted else { return }
            types.append(type)
        }
        for identifier in ["net.daringfireball.markdown", "public.markdown", "com.unknown.md", "org.commonmark.markdown"] {
            add(UTType(identifier))
        }
        for ext in MarkdownFile.extensions { add(UTType(filenameExtension: ext)) }
        return types
    }

    static func isDefault(app: URL = Bundle.main.bundleURL) -> Bool {
        let target = app.resolvingSymlinksInPath().standardizedFileURL
        let probes = contentTypes.filter(MarkdownFile.canBecomeDefault)
        guard !probes.isEmpty else { return false }
        return probes.allSatisfy { type in
            NSWorkspace.shared.urlForApplication(toOpen: type)?.resolvingSymlinksInPath().standardizedFileURL == target
        }
    }

    static func makeDefault(app: URL = Bundle.main.bundleURL, completion: @escaping (Error?) -> Void) {
        let types = contentTypes.filter(MarkdownFile.canBecomeDefault)
        guard !types.isEmpty else { completion(nil); return }
        var remaining = types.count
        var failure: Error?
        for type in types {
            NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { error in
                DispatchQueue.main.async {
                    if failure == nil { failure = error }
                    remaining -= 1
                    if remaining == 0 { completion(failure) }
                }
            }
        }
    }

    static func askIfNeeded() {
        if isDefault() {
            UserDefaults.standard.set(true, forKey: askedKey)
            return
        }
        guard !UserDefaults.standard.bool(forKey: askedKey) else { return }
        let alert = NSAlert()
        alert.messageText = "Use Aster for Markdown files?"
        alert.informativeText = "Finder can open .md files in Aster when you double-click them. You can change this later in Aster Settings."
        alert.addButton(withTitle: "Use Aster")
        alert.addButton(withTitle: "Not Now")
        let useAster = alert.runModal() == .alertFirstButtonReturn
        UserDefaults.standard.set(true, forKey: askedKey)
        guard useAster else { return }
        makeDefault { error in
            if let error { NSAlert(error: error).runModal() }
        }
    }
}

private struct AsterSettings: View {
    @Binding var appearance: AsterAppearance
    @AppStorage("fontSize") private var fontSize = 16.0
    @AppStorage("restoreSession") private var restoreSession = true
    @AppStorage("autoSave") private var autoSave = false
    @AppStorage("mermaid") private var mermaid = true
    @AppStorage("math") private var math = true
    @AppStorage("frontMatter") private var frontMatter = true
    @State private var markdownDefault = MarkdownDefault.isDefault()
    @State private var defaultError: String?

    var body: some View {
        Form {
            Section("Workspace") {
                Toggle("Reopen documents and workspace on launch", isOn: $restoreSession)
                Toggle("Automatically save changes", isOn: $autoSave)
                if markdownDefault {
                    Text("Aster opens Markdown files from Finder.")
                } else {
                    Button("Make Aster the default for Markdown") {
                        MarkdownDefault.makeDefault { error in
                            defaultError = error?.localizedDescription
                            markdownDefault = error == nil
                        }
                    }
                    if let defaultError { Text(defaultError).foregroundStyle(.red) }
                }
            }
            Section("Reading") {
                Picker("Appearance", selection: $appearance) {
                    Text("Dark").tag(AsterAppearance.dark)
                    Text("Light").tag(AsterAppearance.light)
                    Text("Follow macOS").tag(AsterAppearance.system)
                }
                Stepper("Text size  \(Int(fontSize)) pt", value: $fontSize, in: 12...28)
                Toggle("Render Mermaid diagrams", isOn: $mermaid)
                Toggle("Render math", isOn: $math)
                Toggle("Show YAML front matter", isOn: $frontMatter)
            }
        }
        .formStyle(.grouped).frame(width: 450, height: 430)
    }
}
