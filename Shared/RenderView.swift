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

final class LocalImageLoader: NSObject, WKURLSchemeHandler {
    var document: URL?
    var directory: URL?

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
        guard let document, let directory else { return nil }
        return ImageAsset.read(address, document: document, directory: directory)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class RenderView: NSViewController, WKNavigationDelegate, WKScriptMessageHandler {
    private let imageLoader = LocalImageLoader()
    private var webView: WKWebView!
    private var ready = false
    private var source = ""
    private var options = RenderOptions()
    private var document: URL?
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
        guard let url = Bundle.main.url(forResource: "preview", withExtension: "html", subdirectory: "Bundle") else { return }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func update(_ text: String, url: URL?, directory: URL?, options: RenderOptions) {
        guard self.source != text || self.document != url || self.options != options || imageLoader.directory != directory else {
            if ready { finishPreview(nil) }
            return
        }
        preserveScroll = document == url
        if !preserveScroll { targetLine = nil }
        source = text
        document = url
        self.options = options
        imageLoader.document = url
        imageLoader.directory = directory ?? url?.deletingLastPathComponent()
        if ready {
            renderTask?.cancel()
            renderTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(preserveScroll ? 100 : 0))
                guard !Task.isCancelled else { return }
                render()
            }
        }
    }

    func prepare(_ text: String, url: URL, completion: @escaping (Error?) -> Void) {
        finishPreview(CancellationError())
        previewCompletion = completion
        _ = view
        update(text, url: url, directory: url.deletingLastPathComponent(), options: RenderOptions())
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

    func makePDF() async throws -> Data {
        try await webView.pdf()
    }

    func html() async throws -> String {
        let content = try await webView.callAsyncJavaScript("return await exportContent()", arguments: [:], in: nil, contentWorld: .page)
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

    func printDocument() {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        let operation = webView.printOperation(with: info)
        if let window = view.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        render()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishPreview(error)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if !ready, navigationAction.request.url?.lastPathComponent == "preview.html" {
            decisionHandler(.allow)
        } else if navigationAction.request.url?.fragment != nil,
                  navigationAction.request.url?.deletingLastPathComponent() == webView.url?.deletingLastPathComponent(),
                  navigationAction.request.url?.lastPathComponent == "preview.html" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String, let value = body["value"] else { return }
        receive?(kind, value)
    }

    private func render() {
        webView.callAsyncJavaScript("await render(source, options)",
                                   arguments: ["source": source, "options": options.arguments(preserveScroll: preserveScroll)],
                                   in: nil, in: .page) { [weak self] result in
            guard let self else { return }
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
