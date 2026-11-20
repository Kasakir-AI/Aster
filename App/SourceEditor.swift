import AppKit
import SwiftUI

struct SourceEditor: NSViewRepresentable {
    let note: Note
    let model: Library
    let fontSize: Double
    let jump: Library.Jump?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let editor = SourceTextView(frame: .zero)
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.allowsUndo = true
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.textContainerInset = NSSize(width: 23, height: 20)
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("Markdown source")
        scroll.documentView = editor
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak editor] _ in
            MainActor.assumeIsolated { editor?.scrolled() }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? SourceTextView else { return }
        let coordinator = context.coordinator
        coordinator.note = note
        coordinator.model = model
        editor.onScroll = { [weak model] value in
            guard model?.mode == .split else { return }
            model?.renderer?.scroll(to: value)
        }
        editor.focusMode = model.focusMode
        editor.typewriter = model.typewriter
        editor.usesStyledSource = model.mode == .styled
        editor.setEditorFont(size: fontSize)
        if editor.string != note.text {
            let selection = editor.selectedRange()
            editor.string = note.text
            editor.setSelectedRange(NSRange(location: min(selection.location, (note.text as NSString).length), length: 0))
        }
        editor.highlight()
        if let jump, coordinator.lastJump != jump.id {
            coordinator.lastJump = jump.id
            DispatchQueue.main.async { editor.jump(to: jump.line) }
        }
        if model.editor !== editor {
            DispatchQueue.main.async { [weak model, weak editor] in
                guard let editor, editor.window != nil else { return }
                model?.editor = editor
                editor.window?.makeFirstResponder(editor)
            }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.scrollObserver { NotificationCenter.default.removeObserver(observer) }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var note: Note?
        weak var model: Library?
        var scrollObserver: (any NSObjectProtocol)?
        var lastJump: UUID?

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? SourceTextView, let note else { return }
            model?.edit(note, text: editor.string)
            editor.highlight()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? SourceTextView else { return }
            editor.selectionMoved()
        }
    }
}

final class SourceTextView: NSTextView {
    var onScroll: ((Double) -> Void)?
    var focusMode = false
    var typewriter = false
    var usesStyledSource = false {
        didSet { if oldValue != usesStyledSource { highlighted = nil } }
    }
    private var editorSize: Double = 0
    private var fontMode = false
    private var suppressScrollUntil = Date.distantPast
    private var highlighted: String?
    private var highlightTask: Task<Void, Never>?
    private static let patterns: [(NSRegularExpression, NSColor)] = [
        ("(?m)^ {0,3}#{1,6}(?:[ \\t].*)?$", .systemPurple),
        ("(?m)^\\s*(?:[-+*]|[0-9]+[.)])\\s+(?:\\[[ xX]\\]\\s+)?", .systemIndigo),
        ("(?m)^\\s*>.*$", .systemGray),
        ("\\*\\*[^*\\n]+\\*\\*|__[^_\\n]+__|~~[^~\\n]+~~", .systemPurple),
        ("\\]\\([^\\n)]*\\)", .systemBlue),
        ("`[^`\\n]+`", .systemOrange),
        ("(?ms)^ {0,3}(?:`{3,}|~{3,})[^\\n]*\\n.*?^ {0,3}(?:`{3,}|~{3,})[^\\n]*", .systemBrown)
    ].compactMap { pattern, color in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, color) }
    }

    func setEditorFont(size: Double) {
        guard editorSize != size || fontMode != usesStyledSource else { return }
        editorSize = size
        fontMode = usesStyledSource
        font = usesStyledSource ? .systemFont(ofSize: size + 1) : .monospacedSystemFont(ofSize: size, weight: .regular)
        highlighted = nil
    }

    func highlight() {
        highlightTask?.cancel()
        highlightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(65))
            guard !Task.isCancelled else { return }
            self?.applyHighlight()
        }
    }

    private func applyHighlight() {
        guard let layoutManager, let storage = textStorage, storage.length < 1_500_000 else { return }
        let source = string
        if highlighted == source && !focusMode && !usesStyledSource { return }
        highlighted = focusMode ? nil : source
        let range = NSRange(location: 0, length: storage.length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        for (regex, color) in Self.patterns {
            regex.enumerateMatches(in: source, range: range) { result, _, _ in
                if let result { layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: result.range) }
            }
        }
        if usesStyledSource { styleSource(storage, source: source) }
        if focusMode {
            let paragraph = (source as NSString).paragraphRange(for: selectedRange())
            let dim = NSColor.secondaryLabelColor.withAlphaComponent(0.55)
            layoutManager.addTemporaryAttribute(.foregroundColor, value: dim,
                                                forCharacterRange: NSRange(location: 0, length: paragraph.location))
            layoutManager.addTemporaryAttribute(.foregroundColor, value: dim,
                                                forCharacterRange: NSRange(location: NSMaxRange(paragraph), length: range.length - NSMaxRange(paragraph)))
        }
    }

    private func styleSource(_ storage: NSTextStorage, source: String) {
        let text = source as NSString
        let range = NSRange(location: 0, length: text.length)
        let active = text.paragraphRange(for: selectedRange())
        let ordinary = NSFont.systemFont(ofSize: editorSize + 1)
        guard range.length > 0 else { return }
        storage.beginEditing()
        storage.addAttribute(.font, value: ordinary, range: range)
        for heading in WorkspaceIndex.headings(in: source) {
            guard let line = MarkdownFile.range(ofLine: heading.line, in: source), NSIntersectionRange(line, active).length == 0 else { continue }
            let display = NSFont.systemFont(ofSize: editorSize + max(2, 13 - 2 * Double(heading.level)), weight: .semibold)
            storage.addAttribute(.font, value: display, range: line)
            let row = text.substring(with: line)
            if let prefix = row.firstMatch(of: /^ {0,3}#{1,6} +/) {
                let marker = NSRange(prefix.range, in: row)
                layoutManager?.addTemporaryAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor,
                    forCharacterRange: NSRange(location: line.location + marker.location, length: marker.length))
            }
        }
        storage.endEditing()
    }

    func selectionMoved() {
        if focusMode || usesStyledSource { highlight() }
        guard typewriter, let layoutManager, let scroll = enclosingScrollView, let container = textContainer else { return }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(selectedRange().location, max(0, (string as NSString).length - 1)))
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: layoutManager.numberOfGlyphs > glyph ? 1 : 0), in: container)
        scrollTo(x: scroll.contentView.bounds.minX, y: rect.midY + textContainerInset.height - scroll.contentView.bounds.height / 2)
    }

    func jump(to line: Int) {
        guard let range = MarkdownFile.range(ofLine: line, in: string) else { return }
        setSelectedRange(NSRange(location: range.location, length: 0))
        scrollRangeToVisible(range)
    }

    func scrolled() {
        guard Date() >= suppressScrollUntil, let scroll = enclosingScrollView else { return }
        let total = frame.height - scroll.contentView.bounds.height
        guard total > 0 else { return }
        onScroll?(max(0, min(1, scroll.contentView.bounds.minY / total)))
    }

    func scroll(to fraction: Double) {
        guard let scroll = enclosingScrollView else { return }
        suppressScrollUntil = Date().addingTimeInterval(0.2)
        scrollTo(x: scroll.contentView.bounds.minX, y: fraction * max(0, frame.height - scroll.contentView.bounds.height))
    }

    private func scrollTo(x: CGFloat, y: CGFloat) {
        guard let scroll = enclosingScrollView else { return }
        scroll.contentView.scroll(to: NSPoint(x: x, y: max(0, y)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func wrap(with marker: String, suffix: String? = nil, placeholder: String = "text") {
        let end = suffix ?? marker
        let range = selectedRange()
        let source = string as NSString
        let value = range.length == 0 ? placeholder : source.substring(with: range)
        let startLength = (marker as NSString).length
        let endLength = (end as NSString).length
        if range.location >= startLength, NSMaxRange(range) + endLength <= source.length,
           source.substring(with: NSRange(location: range.location - startLength, length: startLength)) == marker,
           source.substring(with: NSRange(location: NSMaxRange(range), length: endLength)) == end {
            let wrapped = NSRange(location: range.location - startLength, length: range.length + startLength + endLength)
            insertText(value, replacementRange: wrapped)
            setSelectedRange(NSRange(location: wrapped.location, length: range.length))
        } else {
            insertText(marker + value + end, replacementRange: range)
            setSelectedRange(NSRange(location: range.location + startLength, length: (value as NSString).length))
        }
    }

    func replaceSource(_ source: String) {
        let previous = selectedRange()
        insertText(source, replacementRange: NSRange(location: 0, length: (string as NSString).length))
        if NSMaxRange(previous) <= (source as NSString).length { setSelectedRange(previous) }
    }

    func find(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        performTextFinderAction(item)
    }
}
