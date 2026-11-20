import AppKit
import XcodeKit

final class SourceExtension: NSObject, XCSourceEditorExtension {}

final class SourceCommand: NSObject, XCSourceEditorCommand {
    func perform(with invocation: XCSourceEditorCommandInvocation, completionHandler: @escaping (Error?) -> Void) {
        let source = invocation.buffer.completeBuffer
        guard !source.isEmpty else { completionHandler(HandoffError.empty); return }
        guard let address = PreviewTransfer.address(for: source) else { completionHandler(HandoffError.tooLarge); return }
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        DispatchQueue.main.async {
            NSWorkspace.shared.open([address], withApplicationAt: app, configuration: .init()) { _, error in
                completionHandler(error)
            }
        }
    }
}

private enum HandoffError: LocalizedError {
    case empty, tooLarge

    var errorDescription: String? {
        switch self {
        case .empty: "Open a Markdown document in Xcode first."
        case .tooLarge: "This buffer is too large to send. Open the Markdown file directly in Aster."
        }
    }
}
