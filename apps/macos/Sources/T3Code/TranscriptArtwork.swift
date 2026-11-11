import AppKit
import WebKit

struct TranscriptArtwork: Hashable {
    enum Kind: String {
        case math, mermaid

        var title: String { self == .math ? "Equation" : "Mermaid Diagram" }
    }

    let kind: Kind
    let source: String
    let dark: Bool
    let inlineFontSize: CGFloat?

    init(kind: Kind, source: String, dark: Bool, inlineFontSize: CGFloat? = nil) {
        self.kind = kind
        self.source = source
        self.dark = dark
        self.inlineFontSize = inlineFontSize
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func missing(in content: NSAttributedString) -> Set<Self> {
        var result: Set<Self> = []
        content.enumerateAttribute(TranscriptCode.attribute, in: NSRange(location: 0, length: content.length)) { value, range, _ in
            if let artwork = (value as? TranscriptCode)?.artwork, content.attribute(.attachment, at: range.location, effectiveRange: nil) == nil {
                result.insert(artwork)
            }
        }
        return result
    }
}

struct TranscriptArtworkImage {
    let image: NSImage
    let descent: CGFloat
}

enum TranscriptRenderingRequest: Hashable {
    case math(String)
    case artwork(TranscriptArtwork)

    static let mathSource = NSAttributedString.Key("T3TranscriptMathSource")

    static func missing(in content: NSAttributedString) -> Set<Self> {
        var requests = Set(TranscriptArtwork.missing(in: content).map(Self.artwork))
        content.enumerateAttribute(mathSource, in: NSRange(location: 0, length: content.length)) { value, _, _ in
            if let source = value as? String { requests.insert(.math(source)) }
        }
        return requests
    }

    @MainActor
    func load(finished: @escaping (Bool) -> Void) {
        switch self {
        case .math(let source):
            Task { finished(!(await TranscriptMathParser.shared.prepare(source)).isEmpty) }
        case .artwork(let artwork):
            TranscriptArtworkRenderer.shared.load(artwork, finished: finished)
        }
    }
}

@MainActor
final class TranscriptArtworkRenderer: NSObject, WKNavigationDelegate {
    static let shared = TranscriptArtworkRenderer()

    private final class CacheKey: NSObject {
        let artwork: TranscriptArtwork
        init(_ artwork: TranscriptArtwork) { self.artwork = artwork }
        override var hash: Int { artwork.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? CacheKey)?.artwork == artwork }
    }

    private final class Result {
        let preview: TranscriptArtworkImage?
        init(_ preview: TranscriptArtworkImage?) { self.preview = preview }
    }

    private let page: URL?
    private let cache = NSCache<CacheKey, Result>()
    private var view: WKWebView?
    private var ready = false
    private var navigation: CheckedContinuation<Void, any Error>?
    private var pending: [TranscriptArtwork: [(Bool) -> Void]] = [:]
    private var queue: [TranscriptArtwork] = []
    private var task: Task<Void, Never>?

    init(page: URL? = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "TranscriptRenderer")) {
        self.page = page
        super.init()
        cache.countLimit = 150
        cache.totalCostLimit = 24 * 1024 * 1024
    }

    func preview(for artwork: TranscriptArtwork) -> TranscriptArtworkImage? {
        cache.object(forKey: CacheKey(artwork))?.preview
    }

    func load(_ artwork: TranscriptArtwork, finished: @escaping (Bool) -> Void) {
        guard page != nil, artwork.source.utf8.count <= 64_000 else { finished(false); return }
        if let result = cache.object(forKey: CacheKey(artwork)) {
            Task { finished(result.preview != nil) }
            return
        }
        if pending[artwork] == nil { queue.append(artwork) }
        pending[artwork, default: []].append(finished)
        guard task == nil else { return }
        task = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let artwork = queue.removeFirst()
            let capture = try? await render(artwork)
            let preview = capture.flatMap { data, descent in
                NSImage(data: data).map { image in
                    image.accessibilityDescription = artwork.kind == .math ? "Equation \(artwork.source)" : artwork.kind.title
                    return TranscriptArtworkImage(image: image, descent: descent)
                }
            }
            cache.setObject(Result(preview), forKey: CacheKey(artwork), cost: (capture?.data.count ?? 0) + artwork.source.utf8.count)
            let callbacks = pending.removeValue(forKey: artwork) ?? []
            for callback in callbacks { callback(preview != nil) }
        }
        task = nil
    }

    private func render(_ artwork: TranscriptArtwork) async throws -> (data: Data, descent: CGFloat)? {
        let view = try await pageView()
        let result = try await view.callAsyncJavaScript("return renderArtwork(kind, source, dark, inlineFontSize)", arguments: [
            "kind": artwork.kind.rawValue, "source": artwork.source, "dark": artwork.dark,
            "inlineFontSize": Double(artwork.inlineFontSize ?? 0),
        ], contentWorld: .page)
        guard let size = result as? [String: Double], let width = size["width"], let height = size["height"],
              let descent = size["descent"], (1...1080).contains(width), (1...1400).contains(height),
              (0...height).contains(descent) else { return nil }
        let config = WKPDFConfiguration()
        config.rect = NSRect(x: 0, y: 0, width: width, height: height)
        config.allowTransparentBackground = artwork.kind == .math
        let pdf = try await view.pdf(configuration: config)
        return pdf.count <= 2 * 1024 * 1024 ? (pdf, CGFloat(descent)) : nil
    }

    private func pageView() async throws -> WKWebView {
        if ready, let view { return view }
        guard let page else { throw ClientError.invalidResponse }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 1420), configuration: config)
        self.view = view
        view.navigationDelegate = self
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            navigation = continuation
            view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return view
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.standardizedFileURL == page?.standardizedFileURL ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard view === webView else { return }
        ready = true
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
        ready = false
        view = nil
        navigation?.resume(throwing: error)
        navigation = nil
    }
}

@MainActor
final class TranscriptArtworkCell: NSTextAttachmentCell {
    private let naturalSize: NSSize
    private let descent: CGFloat

    init(_ preview: TranscriptArtworkImage) {
        naturalSize = preview.image.size
        descent = preview.descent
        super.init(imageCell: preview.image)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let scale = min(1, max(1, lineFrag.width) / naturalSize.width)
        return NSRect(x: 0, y: -descent * scale, width: floor(naturalSize.width * scale), height: ceil(naturalSize.height * scale))
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        image?.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
