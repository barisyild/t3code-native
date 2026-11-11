import AppKit
import WebKit

@MainActor
private final class HtmlReplyDocuments: NSObject, WKURLSchemeHandler {
    static let scheme = "t3-visual-reply"
    let wrapperURL: URL
    let pageURL: URL
    private let wrapper: Data
    private let page: Data

    init(page: Data, app: McpAppPage?) {
        let id = UUID().uuidString.lowercased()
        let pageURL = URL(string: "\(Self.scheme)://page/\(id)")!
        wrapperURL = URL(string: "\(Self.scheme)://view/\(id)")!
        self.pageURL = pageURL
        let allow = app.map { "allow=\"\($0.allow)\"" } ?? ""
        wrapper = Data("""
            <!doctype html><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; frame-src \(Self.scheme):; style-src 'unsafe-inline'; base-uri 'none'">
            <style>
            html,body{width:100%;height:100%;margin:0;overflow:hidden;background:Canvas;color-scheme:light dark}
            iframe{display:block;width:100%;height:100%;border:0}
            </style>
            <iframe id="visual-reply" sandbox="allow-scripts allow-forms" \(allow) referrerpolicy="no-referrer" src="\(pageURL.absoluteString)"></iframe>
            """.utf8)
        self.page = page
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let request = urlSchemeTask.request
        guard request.httpMethod == "GET", let url = request.url, let document = bytes(for: url) else {
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
            return
        }
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: document.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(document)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private func bytes(for url: URL) -> Data? {
        switch url {
        case wrapperURL: wrapper
        case pageURL: page
        default: nil
        }
    }
}

@MainActor
private final class HtmlReplyScriptBridge: NSObject, WKScriptMessageHandler {
    weak var view: HtmlReplyWebView?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        view?.receive(message)
    }
}

@MainActor
private final class McpAppScriptBridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var view: HtmlReplyWebView?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let view else { return (nil, "The app was closed.") }
        do {
            let response = try await view.receiveAppRequest(message)
            let data = try JSONEncoder().encode(response)
            return (try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed), nil)
        } catch { return (nil, error.localizedDescription) }
    }
}

@MainActor
final class HtmlReplyWebView: NSView, WKNavigationDelegate {
    private static let contentWorld = WKContentWorld.world(name: "T3VisualReply")
    private static let dataStore = WKWebsiteDataStore.nonPersistent()
    private let documents: HtmlReplyDocuments
    private let webView: WKWebView
    private let app: McpAppPage?
    private var navigation: WKNavigation?
    private var pageStarted = false
    private var ready = false
    private var appReady = false
    private var activation: ContinuousClock.Instant?
    private var lastLayoutSize = NSSize.zero
    private var pendingToolCall: Wire?
    private var toolDefinition: Wire = .null
    private var themeTask: Task<Void, Never>?
    var onSize: ((CGFloat) -> Void)?
    var onFailure: ((String) -> Void)?
    var onAppRequest: ((String, Wire) async throws -> Wire)?
    var onAppLeftPage: (() -> Void)?
    var fullscreen = false { didSet { syncTheme() } }

    var zoom: CGFloat {
        get { webView.pageZoom }
        set { webView.pageZoom = newValue }
    }

    init(data: Data, title: String, zoom: CGFloat, app: McpAppPage?, width: CGFloat, appearance: NSAppearance) throws {
        let documents = HtmlReplyDocuments(page: data, app: app)
        self.documents = documents
        self.app = app
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(documents, forURLScheme: HtmlReplyDocuments.scheme)
        let bridge = HtmlReplyScriptBridge()
        configuration.userContentController.add(bridge, contentWorld: Self.contentWorld, name: "visualReply")
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.pageScript(url: documents.pageURL, interactiveApp: app != nil), injectionTime: .atDocumentStart,
            forMainFrameOnly: false, in: Self.contentWorld
        ))
        var appBridge: McpAppScriptBridge?
        if let app {
            let bridge = McpAppScriptBridge()
            appBridge = bridge
            configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: Self.contentWorld, name: "mcpApp")
            let script = try Self.appScript(app: app, appearance: appearance, width: width)
            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                                                            forMainFrameOnly: true, in: Self.contentWorld))
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        bridge.view = self
        appBridge?.view = self
        webView.navigationDelegate = self
        webView.pageZoom = zoom
        webView.setAccessibilityLabel(title)
        fill(webView, in: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func load() { navigation = webView.load(URLRequest(url: documents.wrapperURL)) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        syncTheme()
    }

    override func layout() {
        super.layout()
        if app != nil && bounds.size != lastLayoutSize {
            lastLayoutSize = bounds.size
            syncTheme()
        }
    }

    func setToolCall(_ call: Wire) {
        pendingToolCall = call
        sendToolCall()
    }

    func setToolDefinition(_ tool: Wire) {
        toolDefinition = tool
        syncTheme()
    }

    func teardown() async {
        appReady = false
        activation = nil
        if app != nil, ready {
            _ = try? await webView.callAsyncJavaScript("await globalThis.t3McpApp?.teardown();", contentWorld: Self.contentWorld)
        }
    }

    func consumeActivation() -> Bool {
        guard let activation, activation.duration(to: ContinuousClock().now) <= .seconds(5), webView.window?.isKeyWindow == true,
              let responder = webView.window?.firstResponder as? NSView,
              responder === webView || responder.isDescendant(of: webView) else { return false }
        self.activation = nil
        return true
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url, let frame = action.targetFrame else { return .cancel }
        if frame.isMainFrame { return url == documents.wrapperURL ? .allow : .cancel }
        if Self.withoutFragment(url) == documents.pageURL {
            if !pageStarted { pageStarted = true; return .allow }
            if url.fragment != nil && Self.withoutFragment(action.sourceFrame.request.url) == documents.pageURL { return .allow }
        }
        if let app {
            if Self.withoutFragment(frame.request.url) == documents.pageURL {
                appReady = false
                activation = nil
                onAppLeftPage?()
            } else if !action.sourceFrame.isMainFrame && app.allowsFrame(url) {
                return .allow
            }
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard self.navigation === navigation else { return }
        ready = true
        syncTheme()
        sendToolCall()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if self.navigation === navigation { failed(error) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if self.navigation === navigation { failed(error) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { onFailure?("The page renderer stopped.") }

    private func failed(_ error: any Error) {
        guard (error as? URLError)?.code != .cancelled else { return }
        onFailure?("The page could not be displayed.")
    }

    func receive(_ message: WKScriptMessage) {
        guard message.webView === webView, !message.frameInfo.isMainFrame,
              Self.withoutFragment(message.frameInfo.request.url) == documents.pageURL,
              let event = message.body as? [String: Any] else { return }
        switch event["type"] as? String {
        case "size":
            guard let width = event["width"] as? Double, let height = event["height"] as? Double,
                  width.isFinite, width > 0, height.isFinite, height >= 0 else { return }
            let expectedWidth = webView.bounds.width / zoom
            if abs(expectedWidth - width) <= 20 { onSize?(min(20_000, height)) }
        case "link":
            if let url = Self.linkURL(event["url"] as? String) { NSWorkspace.shared.open(url) }
        case "appReady":
            if app != nil { appReady = true }
        case "activation":
            if appReady { activation = ContinuousClock().now }
        default: break
        }
    }

    func receiveAppRequest(_ message: WKScriptMessage) async throws -> Wire {
        guard app != nil, message.webView === webView, message.frameInfo.isMainFrame, message.frameInfo.request.url == documents.wrapperURL,
              let object = message.body as? [String: Any], JSONSerialization.isValidJSONObject(object),
              let method = object["method"] as? String, let onAppRequest else { throw ClientError.invalidResponse }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard data.count <= 512 * 1024 else { throw ClientError.message("The app request is too large.") }
        let request = try JSONDecoder().decode(Wire.self, from: data)
        if method == "leftPage" {
            appReady = false
            onAppLeftPage?()
            return .null
        }
        guard appReady else { throw ClientError.message("The app is unavailable.") }
        return try await onAppRequest(method, request["params"])
    }

    static func linkURL(_ raw: String?) -> URL? {
        guard let raw, raw.utf8.count <= 8_192, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host() != nil, url.user() == nil, url.password() == nil else { return nil }
        return url
    }

    private func syncTheme() {
        guard ready else { return }
        if app != nil {
            let context = Self.appContext(appearance: effectiveAppearance, size: bounds.size, fullscreen: fullscreen, tool: toolDefinition)
            themeTask?.cancel()
            themeTask = Task { [weak webView] in
                guard !Task.isCancelled, let webView else { return }
                _ = try? await webView.callAsyncJavaScript("globalThis.t3McpApp?.update(context);",
                                                           arguments: ["context": context], contentWorld: Self.contentWorld)
            }
            return
        }
        let message = HtmlReplyTheme.message(appearance: effectiveAppearance)
        themeTask?.cancel()
        themeTask = Task { [weak webView] in
            guard !Task.isCancelled, let webView else { return }
            _ = try? await webView.callAsyncJavaScript("""
                document.documentElement.style.colorScheme = theme.params.theme;
                document.documentElement.style.backgroundColor = theme.params.styles.variables["--background"];
                document.getElementById("visual-reply")?.contentWindow?.postMessage(theme, "*");
                """, arguments: ["theme": message], contentWorld: Self.contentWorld)
        }
    }

    private func sendToolCall() {
        guard ready, let pendingToolCall,
              let data = try? JSONEncoder().encode(pendingToolCall),
              let call = try? JSONSerialization.jsonObject(with: data) else { return }
        Task { [weak webView] in
            _ = try? await webView?.callAsyncJavaScript("globalThis.t3McpApp?.toolCall(call);",
                                                       arguments: ["call": call], contentWorld: Self.contentWorld)
        }
    }

    private static func appScript(app: McpAppPage, appearance: NSAppearance, width: CGFloat) throws -> String {
        let folder = "TranscriptRenderer"
        guard let host = Bundle.main.url(forResource: "mcp-app-host", withExtension: "js", subdirectory: folder),
              let bridge = Bundle.main.url(forResource: "mcp-app-bridge", withExtension: "js", subdirectory: folder)
        else { throw ClientError.message("This build is missing the MCP app host.") }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let context = appContext(appearance: appearance, size: NSSize(width: width, height: 0), fullscreen: false, tool: .null)
        let metadata = String(decoding: try JSONEncoder().encode(app.metadata), as: UTF8.self)
        let styles = String(decoding: try JSONSerialization.data(withJSONObject: context), as: UTF8.self)
        let versionLiteral = String(decoding: try JSONEncoder().encode(version), as: UTF8.self)
        return try String(contentsOf: host, encoding: .utf8) + "\n" + String(contentsOf: bridge, encoding: .utf8) +
            "\nstartT3McpApp(\(metadata), \(styles), \(versionLiteral));"
    }

    private static func appContext(appearance: NSAppearance, size: NSSize, fullscreen: Bool, tool: Wire) -> [String: Any] {
        let theme = HtmlReplyTheme.message(appearance: appearance)["params"] as? [String: Any] ?? [:]
        var context = theme
        context["displayMode"] = fullscreen ? "fullscreen" : "inline"
        context["availableDisplayModes"] = ["inline", "fullscreen"]
        context["containerDimensions"] = fullscreen ? ["width": size.width, "height": size.height] :
            ["width": size.width, "maxHeight": McpAppPage.maximumHeight]
        context["platform"] = "desktop"
        context["locale"] = Locale.preferredLanguages.first ?? "en"
        context["timeZone"] = TimeZone.current.identifier
        context["deviceCapabilities"] = ["touch": false, "hover": true]
        context["safeAreaInsets"] = ["top": 0, "right": 0, "bottom": 0, "left": 0]
        if tool != .null, let data = try? JSONEncoder().encode(tool), let object = try? JSONSerialization.jsonObject(with: data) {
            context["toolInfo"] = ["tool": object]
        }
        return context
    }

    private static func withoutFragment(_ url: URL?) -> URL? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = nil
        return components.url
    }

    private static func pageScript(url: URL, interactiveApp: Bool) -> String {
        // This script runs in an isolated world. The page cannot call the native handler.
        """
        (() => {
          if (location.href.split("#")[0] !== "\(url.absoluteString)") return;
          const report = value => window.webkit.messageHandlers.visualReply.postMessage(value);
          const interactiveApp = \(interactiveApp ? "true" : "false");
          let width = 0, height = 0;
          const measure = () => {
            const root = document.documentElement;
            if (!root) return;
            const w = window.innerWidth;
            const h = Math.ceil(root.scrollHeight > root.clientHeight ? root.scrollHeight : root.getBoundingClientRect().height);
            if (w === width && h === height) return;
            width = w; height = h;
            report({type:"size", width:w, height:h});
          };
          document.addEventListener("DOMContentLoaded", () => {
            if (interactiveApp) { report({type:"appReady"}); return; }
            const observer = new ResizeObserver(measure);
            observer.observe(document.documentElement);
            if (document.body) observer.observe(document.body);
            measure();
          });
          if (interactiveApp) {
            report({type:"appReady"});
            for (const event of ["pointerdown", "pointerup", "keydown"]) {
              document.addEventListener(event, input => {
                if (input.isTrusted) report({type:"activation"});
              }, true);
            }
          } else {
            window.addEventListener("resize", measure);
            window.addEventListener("load", measure);
          }
          document.addEventListener("click", event => {
            if (!event.isTrusted || event.button !== 0) return;
            const link = event.composedPath().find(node => node?.matches?.("a[href]"));
            if (!link) return;
            let url;
            try { url = new URL(link.getAttribute("href"), document.baseURI); } catch { return; }
            if (!["http:", "https:"].includes(url.protocol)) return;
            event.preventDefault();
            event.stopImmediatePropagation();
            report({type:"link", url:url.href});
          }, true);
        })();
        """
    }
}
