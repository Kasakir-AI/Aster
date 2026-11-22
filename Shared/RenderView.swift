import AppKit
import WebKit

struct RenderOptions: Equatable {
    var interactive = false
    var appearance = AsterAppearance.initial
    var fontSize = 16.0
    var diagrams = true
    var math = true
    var metadata = true

    func arguments(preserveScroll: Bool) -> [String: Any] {
        ["interactive": interactive, "appearance": appearance.rawValue, "fontSize": fontSize,
         "diagrams": diagrams, "math": math, "metadata": metadata, "preserveScroll": preserveScroll]
    }
}

struct RenderSnapshot: Equatable {
    struct LocalAssets: Equatable {
        let document: URL
        let directory: URL
    }

    let text: String
    let assets: LocalAssets?
    let options: RenderOptions

    init(_ text: String, document: URL?, workspace: URL? = nil, options: RenderOptions = RenderOptions()) {
        self.text = text
        self.options = options
        self.assets = document.map { url in
            let directory = workspace.flatMap { FolderAccess.contains(url, in: $0) ? $0 : nil }
            return LocalAssets(document: url, directory: directory ?? url.deletingLastPathComponent())
        }
    }
}

private final class LocalImageLoader: NSObject, WKURLSchemeHandler {
    private var assets: RenderSnapshot.LocalAssets?
    private(set) var scope = UUID().uuidString

    func update(_ assets: RenderSnapshot.LocalAssets?) {
        guard self.assets != assets else { return }
        self.assets = assets
        scope = UUID().uuidString
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let address = task.request.url, let asset = image(at: address) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        task.didReceive(URLResponse(url: address, mimeType: asset.mime,
                                    expectedContentLength: asset.data.count, textEncodingName: nil))
        task.didReceive(asset.data)
        task.didFinish()
    }

    func image(at address: URL) -> (mime: String, data: Data)? {
        guard let assets, address.query == "scope=" + scope else { return nil }
        return ImageAsset.read(address, document: assets.document, directory: assets.directory)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class RenderView: NSViewController, WKNavigationDelegate, WKScriptMessageHandler {
    private let imageLoader = LocalImageLoader()
    private var webView: WKWebView!
    private let previewURL = Bundle.main.url(forResource: "preview", withExtension: "html", subdirectory: "Bundle")
    private var ready = false
    private var snapshot: RenderSnapshot?
    private var revision = 0
    var options: RenderOptions { snapshot?.options ?? RenderOptions() }
    private var preserveScroll = false
    private var targetLine: Int?
    private var previewCompletion: ((Error?) -> Void)?
    private var renderTask: Task<Void, Never>?
    var receive: ((String, Any) -> Void)?

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(imageLoader, forURLScheme: "aster-asset")
        configuration.userContentController.add(WeakBridge(owner: self), name: "bridge")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        view = webView
        guard let previewURL else { return }
        webView.loadFileURL(previewURL, allowingReadAccessTo: previewURL.deletingLastPathComponent())
    }

    func update(_ snapshot: RenderSnapshot) {
        guard self.snapshot != snapshot else { return }
        preserveScroll = self.snapshot?.assets?.document == snapshot.assets?.document
        if !preserveScroll { targetLine = nil }
        self.snapshot = snapshot
        revision += 1
        imageLoader.update(snapshot.assets)
        if ready {
            renderTask?.cancel()
            renderTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(preserveScroll ? 100 : 0))
                guard !Task.isCancelled else { return }
                render()
            }
        }
    }

    func prepare(_ snapshot: RenderSnapshot, completion: @escaping (Error?) -> Void) {
        finishPreview(CancellationError())
        guard previewURL != nil else {
            completion(CocoaError(.fileReadNoSuchFile))
            return
        }
        previewCompletion = completion
        _ = view
        if self.snapshot == snapshot, ready {
            renderTask?.cancel()
            render()
        } else {
            update(snapshot)
        }
    }

    func jump(to line: Int) {
        targetLine = line
        guard ready else { return }
        webView.callAsyncJavaScript("jumpToLine(line)", arguments: ["line": line], in: nil, in: .page) { _ in }
    }

    func scroll(to fraction: Double) {
        guard ready else { return }
        webView.callAsyncJavaScript("scrollFraction(fraction)", arguments: ["fraction": fraction], in: nil, in: .page) { _ in }
    }

    func find(_ query: String, backwards: Bool) {
        let settings = WKFindConfiguration()
        settings.backwards = backwards
        webView.find(query, configuration: settings) { _ in }
    }

    static func makePDF(of snapshot: RenderSnapshot, size: CGSize) async throws -> Data {
        let renderer = try await prepareExport(snapshot, size: size)
        return try await renderer.webView.pdf()
    }

    static func html(of snapshot: RenderSnapshot, size: CGSize) async throws -> String {
        let renderer = try await prepareExport(snapshot, size: size)
        return try await renderer.renderedHTML()
    }

    private func renderedHTML() async throws -> String {
        let content = try await webView.callAsyncJavaScript("return exportContent()", arguments: [:], in: nil, contentWorld: .page)
        let cssURL = Bundle.main.url(forResource: "paper", withExtension: "css", subdirectory: "Bundle")
        guard let cssURL, let article = content as? String else { throw CocoaError(.fileReadCorruptFile) }
        let css = try String(contentsOf: cssURL, encoding: .utf8)
        let embedded = ImageAsset.replacingSources(in: article) { url in
            imageLoader.image(at: url).map { "data:" + $0.mime + ";base64," + $0.data.base64EncodedString() }
        }
        return """
        <!doctype html><html lang="en" data-appearance="\(options.appearance.rawValue)"><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'">
        <title>Markdown document</title><style>\(css)</style>\(embedded)</html>
        """
    }

    static func preparePrint(_ snapshot: RenderSnapshot, size: CGSize) async throws -> PrintJob {
        let renderer = try await prepareExport(snapshot, size: size)
        return PrintJob(renderer: renderer, operation: renderer.webView.printOperation(with: NSPrintInfo.shared))
    }

    @MainActor final class PrintJob: NSObject {
        let operation: NSPrintOperation
        private let renderer: RenderView
        private var completion: CheckedContinuation<Bool, Never>?

        fileprivate init(renderer: RenderView, operation: NSPrintOperation) {
            self.renderer = renderer
            self.operation = operation
        }

        func runModal(for window: NSWindow) async -> Bool {
            defer { withExtendedLifetime(self) {} }
            return await withCheckedContinuation { continuation in
                completion = continuation
                operation.runModal(for: window, delegate: self, didRun: #selector(didPrint), contextInfo: nil)
            }
        }

        @objc private func didPrint(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
            let continuation = completion
            completion = nil
            continuation?.resume(returning: success)
        }
    }

    private static func prepareExport(_ snapshot: RenderSnapshot, size: CGSize) async throws -> RenderView {
        let renderer = RenderView()
        renderer.view.frame.size = size
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            renderer.prepare(snapshot) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        _ = try await renderer.webView.callAsyncJavaScript("await waitForImages()", arguments: [:], in: nil, contentWorld: .page)
        return renderer
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        render()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishPreview(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishPreview(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishPreview(WKError(.webContentProcessTerminated))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let address = navigationAction.request.url
        let samePageFragment = navigationAction.sourceFrame.isMainFrame && address?.fragment != nil
        guard navigationAction.targetFrame?.isMainFrame == true,
              isPreviewPage(address), !ready || samePageFragment else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, isPreviewPage(message.frameInfo.request.url),
              let body = message.body as? [String: Any],
              let kind = body["kind"] as? String, let value = body["value"] else { return }
        receive?(kind, value)
    }

    private func isPreviewPage(_ address: URL?) -> Bool {
        guard let previewURL, let address,
              var components = URLComponents(url: address, resolvingAgainstBaseURL: false) else { return false }
        components.fragment = nil
        return components.url == previewURL
    }

    private func render() {
        guard let snapshot else { return }
        let revision = revision
        var arguments = snapshot.options.arguments(preserveScroll: preserveScroll)
        arguments["assetScope"] = imageLoader.scope
        webView.callAsyncJavaScript("await render(source, options)",
                                   arguments: ["source": snapshot.text, "options": arguments],
                                   in: nil, in: .page) { [weak self] result in
            guard let self, self.revision == revision else { return }
            if let line = self.targetLine {
                self.jump(to: line)
                self.targetLine = nil
            }
            switch result {
            case .success: self.finishPreview(nil)
            case .failure(let error): self.finishPreview(error)
            }
        }
    }

    private func finishPreview(_ error: Error?) {
        let completion = previewCompletion
        previewCompletion = nil
        completion?(error)
    }
}

private final class WeakBridge: NSObject, WKScriptMessageHandler {
    weak var owner: RenderView?
    init(owner: RenderView) { self.owner = owner }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.userContentController(userContentController, didReceive: message)
    }
}
