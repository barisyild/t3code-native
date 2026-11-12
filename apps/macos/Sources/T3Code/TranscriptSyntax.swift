import AppKit
import WebKit

struct TranscriptSyntax: Hashable {
    static let attribute = NSAttributedString.Key("T3TranscriptSyntax")

    let source: NSString
    let language: String
    let dark: Bool

    init?(_ source: String, language: String?, dark: Bool) {
        guard let tag = language?.split(whereSeparator: \.isWhitespace).first?.lowercased(),
              !["plain", "plaintext", "text", "txt"].contains(tag),
              !source.isEmpty, source.utf8.count <= 64_000 else { return nil }
        self.source = source as NSString
        self.language = tag
        self.dark = dark
    }
}

@MainActor
final class TranscriptSyntaxRenderer: NSObject, WKNavigationDelegate {
    static let shared = TranscriptSyntaxRenderer()

    private struct Span {
        let range: NSRange
        let color: NSColor
    }

    private final class CacheKey: NSObject {
        let syntax: TranscriptSyntax
        init(_ syntax: TranscriptSyntax) { self.syntax = syntax }
        override var hash: Int { syntax.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? CacheKey)?.syntax == syntax }
    }

    private final class Result {
        let spans: [Span]
        init(_ spans: [Span]) { self.spans = spans }
    }

    private static let page = URL(string: "t3-syntax://renderer/index.html")!
    private let directory: URL?
    private let cache = NSCache<CacheKey, Result>()
    private var view: WKWebView?
    private var navigation: CheckedContinuation<Void, any Error>?
    private var pending: [TranscriptSyntax: [(Bool) -> Void]] = [:]
    private var queue: [TranscriptSyntax] = []
    private var task: Task<Void, Never>?

    var isAvailable: Bool { directory != nil }

    override init() {
        directory = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "TranscriptRenderer/Syntax")?
            .deletingLastPathComponent()
        super.init()
        cache.countLimit = 256
        cache.totalCostLimit = 8 * 1024 * 1024
    }

    @discardableResult
    func apply(_ syntax: TranscriptSyntax, to text: NSMutableAttributedString, offset: Int = 0) -> Bool {
        guard let result = cache.object(forKey: CacheKey(syntax)) else { return false }
        guard offset >= 0, syntax.source.length <= text.length - offset else { return true }
        text.beginEditing()
        for span in result.spans {
            let range = NSRange(location: offset + span.range.location, length: span.range.length)
            text.addAttribute(.foregroundColor, value: span.color, range: range)
        }
        text.endEditing()
        return true
    }

    func load(_ syntax: TranscriptSyntax, finished: @escaping (Bool) -> Void) {
        guard isAvailable else { finished(false); return }
        if let result = cache.object(forKey: CacheKey(syntax)) {
            Task { finished(!result.spans.isEmpty) }
            return
        }
        if pending[syntax] == nil { queue.append(syntax) }
        pending[syntax, default: []].append(finished)
        guard task == nil else { return }
        task = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let syntax = queue.removeFirst()
            let spans = (try? await tokenize(syntax)) ?? []
            cache.setObject(Result(spans), forKey: CacheKey(syntax),
                            cost: 2 * syntax.source.length + spans.count * MemoryLayout<Span>.stride)
            let callbacks = pending.removeValue(forKey: syntax) ?? []
            for callback in callbacks { callback(!spans.isEmpty) }
        }
        task = nil
    }

    private func tokenize(_ syntax: TranscriptSyntax) async throws -> [Span] {
        let view = try await pageView()
        let result = try await view.callAsyncJavaScript("return await highlightSyntax(source, language, dark);", arguments: [
            "source": syntax.source, "language": syntax.language, "dark": syntax.dark,
        ], contentWorld: .page)
        guard let values = result as? [Int], values.count.isMultiple(of: 3) else { return [] }
        var spans: [Span] = []
        var colors: [Int: NSColor] = [:]
        var previousEnd = 0
        for index in stride(from: 0, to: values.count, by: 3) {
            let start = values[index]
            let end = values[index + 1]
            let rgb = values[index + 2]
            guard start >= previousEnd, end > start, end <= syntax.source.length, (0...0xFFFFFF).contains(rgb) else { continue }
            let color = colors[rgb] ?? NSColor(srgbRed: Double((rgb >> 16) & 255) / 255,
                                               green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, alpha: 1)
            colors[rgb] = color
            spans.append(Span(range: NSRange(location: start, length: end - start), color: color))
            previousEnd = end
        }
        return spans
    }

    private func pageView() async throws -> WKWebView {
        if let view { return view }
        guard let directory else { throw ClientError.invalidResponse }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(SyntaxAssets(directory), forURLScheme: "t3-syntax")
        let view = WKWebView(frame: .zero, configuration: config)
        self.view = view
        view.navigationDelegate = self
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            navigation = continuation
            view.load(URLRequest(url: Self.page))
        }
        return view
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        action.request.url == Self.page ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard view === webView else { return }
        self.navigation?.resume()
        self.navigation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        pageFailed(webView, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        pageFailed(webView, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageFailed(webView, error: ClientError.disconnected)
    }

    private func pageFailed(_ webView: WKWebView, error: any Error) {
        guard view === webView else { return }
        view = nil
        navigation?.resume(throwing: error)
        navigation = nil
    }
}

@MainActor
private final class SyntaxAssets: NSObject, WKURLSchemeHandler {
    private let directory: URL

    init(_ directory: URL) {
        self.directory = directory.resolvingSymlinksInPath().standardizedFileURL
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "renderer", task.request.httpMethod == "GET" else {
            task.didFailWithError(URLError(.unsupportedURL))
            return
        }
        let file = directory.appendingPathComponent(String(url.path.dropFirst())).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(directory.path + "/"),
              ["html", "js", "mjs"].contains(file.pathExtension),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = file.pathExtension == "html" ? "text/html" : "text/javascript"
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
            "Content-Type": mime + "; charset=utf-8",
            // WebKit treats custom schemes as opaque origins for module imports.
            "Access-Control-Allow-Origin": "*",
        ]) else {
            task.didFailWithError(URLError(.badServerResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
