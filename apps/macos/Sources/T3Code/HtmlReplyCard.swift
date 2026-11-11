import AppKit

@MainActor
final class HtmlReplyCard: NSView {
    static let chromeHeight: CGFloat = 32
    static let horizontalInsets: CGFloat = 6

    private let reference: ConversationPage
    private let appSession: McpAppSession?
    private let loader: (@MainActor () async throws -> AttachmentFile)?
    private let viewport = NSView()
    private let status = label("Loading page…", size: 12, color: WorkspaceStyle.muted)
    private lazy var retry = ActionButton("Retry", symbol: "arrow.clockwise", style: .subtle) { [weak self] in self?.load() }
    private var loading: Task<Void, Never>?
    private var page: HtmlReplyWebView?
    private var sheet: NSPanel?
    private var failed = false
    private var closingApp = false
    private var asking = false
    private var awaitingUser = false
    private var zoom: CGFloat
    private var zoomButtons: [ZoomButtons] = []
    private weak var expandButton: ActionButton?
    private weak var closeAppButton: ActionButton?
    private var collapseWaiters: [CheckedContinuation<Void, Never>] = []
    var onMetrics: ((_ width: CGFloat, _ zoom: CGFloat, _ liveHeight: CGFloat?) -> Void)?

    private struct ZoomButtons {
        let out: ActionButton
        let reset: ActionButton
        let inward: ActionButton
    }

    init(reference: ConversationPage, zoom: CGFloat, appSession: McpAppSession?,
         loader: (@MainActor () async throws -> AttachmentFile)?) {
        self.reference = reference
        self.appSession = appSession
        self.zoom = zoom
        self.loader = loader
        super.init(frame: .zero)
        let header = toolbar(close: nil)
        header.heightAnchor.constraint(equalToConstant: 22).isActive = true
        if reference.app?.prefersBorder == true {
            viewport.wantsLayer = true
            viewport.layer?.borderWidth = 1
            viewport.layer?.cornerRadius = 8
            viewport.layer?.masksToBounds = true
            updateBorder()
        }
        status.maximumNumberOfLines = 2
        let message = column([status, retry], spacing: 6, alignment: .centerX)
        viewport.addSubview(message)
        message.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            message.centerXAnchor.constraint(equalTo: viewport.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: viewport.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: viewport.widthAnchor, constant: -16),
        ])
        retry.isHidden = true
        if loader == nil { status.stringValue = "Connect to the environment to view this page." }
        fill(column([header, viewport], spacing: 4, alignment: .width), in: self, inset: 3)
        updateZoomButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            loading?.cancel()
            loading = nil
            if let sheet {
                Task { [weak self, weak sheet] in
                    guard let self, window == nil, let sheet, self.sheet === sheet, let parent = sheet.sheetParent else { return }
                    parent.endSheet(sheet)
                }
            }
        } else if page == nil && !failed {
            load()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    func setAwaitingUser(_ value: Bool) {
        guard reference.app != nil, awaitingUser != value else { return }
        awaitingUser = value
        if value, let sheet, let parent = sheet.sheetParent { parent.endSheet(sheet) }
        updateZoomButtons()
    }

    private func updateBorder() {
        if reference.app?.prefersBorder == true {
            effectiveAppearance.performAsCurrentDrawingAppearance { viewport.layer?.borderColor = WorkspaceStyle.outline.cgColor }
        }
    }

    private func load() {
        guard let loader, loading == nil else { return }
        page?.removeFromSuperview()
        page = nil
        failed = false
        status.isHidden = false
        status.stringValue = "Loading page…"
        retry.isHidden = true
        retry.title = "Retry"
        retry.setAccessibilityLabel("Retry")
        updateZoomButtons()
        loading = Task { [weak self] in
            do {
                let file = try await loader()
                let data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: file.url, options: .mappedIfSafe)
                }.value
                try Task.checkCancellation()
                guard let self else { return }
                loading = nil
                let page = try HtmlReplyWebView(data: data, title: reference.title, zoom: zoom, app: reference.app,
                                                width: viewport.bounds.width, appearance: effectiveAppearance)
                self.page = page
                page.onSize = { [weak self] height in
                    guard let self, sheet == nil, window != nil else { return }
                    onMetrics?(viewport.bounds.width, zoom, height)
                }
                page.onFailure = { [weak self] message in self?.showError(message) }
                if let appSession {
                    page.onAppRequest = { [weak self, weak page] method, params in
                        guard let self, let page else { throw ClientError.disconnected }
                        return try await handleApp(method, params: params, page: page, session: appSession)
                    }
                    page.onAppLeftPage = { [weak self] in
                        Task { await self?.stopApp(leftPage: true) }
                    }
                    loadAppData(appSession, page: page)
                }
                status.isHidden = true
                fill(page, in: viewport)
                updateZoomButtons()
                page.load()
            } catch {
                guard let self, !Task.isCancelled else { return }
                loading = nil
                showError(error.localizedDescription)
            }
        }
    }

    private func showError(_ message: String) {
        failed = true
        if let sheet, let parent = sheet.sheetParent { parent.endSheet(sheet) }
        page?.removeFromSuperview()
        page = nil
        status.isHidden = false
        status.stringValue = message
        retry.isHidden = false
        onMetrics?(viewport.bounds.width, zoom, 90)
        updateZoomButtons()
    }

    private func toolbar(close: (() -> Void)?) -> NSStackView {
        let title = label(reference.title, size: 12, weight: .medium, color: WorkspaceStyle.secondary)
        title.lineBreakMode = .byTruncatingTail
        title.toolTip = reference.title
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if reference.app != nil {
            if let close {
                let done = ActionButton("Done", style: .subtle, action: close)
                done.keyEquivalent = "\u{1b}"
                return row([title, NSView(), done], spacing: 4)
            }
            let expand = ActionButton("Expand App", symbol: "arrow.up.left.and.arrow.down.right", iconOnly: true, style: .subtle) { [weak self] in
                _ = self?.expand()
            }
            let stop = ActionButton("Close App", symbol: "xmark", iconOnly: true, style: .subtle) { [weak self] in
                Task { await self?.stopApp(leftPage: false) }
            }
            expand.widthAnchor.constraint(equalToConstant: 22).isActive = true
            stop.widthAnchor.constraint(equalToConstant: 22).isActive = true
            expandButton = expand
            closeAppButton = stop
            return row([title, NSView(), expand, stop], spacing: 4)
        }
        let out = ActionButton("Zoom Out", symbol: "minus", iconOnly: true, style: .subtle) { [weak self] in self?.changeZoom(by: -0.25) }
        let reset = ActionButton("100%", style: .subtle) { [weak self] in self?.setZoom(1) }
        let inward = ActionButton("Zoom In", symbol: "plus", iconOnly: true, style: .subtle) { [weak self] in self?.changeZoom(by: 0.25) }
        reset.setAccessibilityLabel("Reset Page Zoom")
        reset.toolTip = "Reset Page Zoom"
        reset.widthAnchor.constraint(equalToConstant: 49).isActive = true
        zoomButtons.append(ZoomButtons(out: out, reset: reset, inward: inward))
        let last: ActionButton
        if let close {
            last = ActionButton("Done", style: .subtle, action: close)
            last.keyEquivalent = "\u{1b}"
        } else {
            last = ActionButton("Expand Page", symbol: "arrow.up.left.and.arrow.down.right", iconOnly: true, style: .subtle) { [weak self] in _ = self?.expand() }
            last.widthAnchor.constraint(equalToConstant: 22).isActive = true
            expandButton = last
        }
        out.widthAnchor.constraint(equalToConstant: 22).isActive = true
        inward.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return row([title, NSView(), out, reset, inward, last], spacing: 4)
    }

    private func updateZoomButtons() {
        expandButton?.isEnabled = page != nil && sheet == nil && !awaitingUser && !asking && !closingApp
        closeAppButton?.isEnabled = page != nil && !closingApp
        for buttons in zoomButtons {
            buttons.out.isEnabled = page != nil && zoom > 0.5
            buttons.inward.isEnabled = page != nil && zoom < 2
            buttons.reset.isEnabled = page != nil && zoom != 1
            buttons.reset.title = "\(Int((zoom * 100).rounded()))%"
        }
    }

    private func changeZoom(by step: CGFloat) { setZoom(zoom + step) }

    private func setZoom(_ requested: CGFloat) {
        let next = min(2, max(0.5, requested))
        guard let page, next != zoom else { return }
        zoom = next
        page.zoom = next
        updateZoomButtons()
        onMetrics?(viewport.bounds.width, zoom, nil)
    }

    @discardableResult
    private func expand() -> Bool {
        guard let parent = window, let page, sheet == nil, parent.attachedSheet == nil, !awaitingUser, !asking, !closingApp else { return false }
        let size = NSSize(width: max(400, parent.contentLayoutRect.width - 30), height: max(300, parent.contentLayoutRect.height - 42))
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        panel.title = reference.title
        panel.contentMinSize = NSSize(width: 380, height: 280)
        let surface = Surface(WorkspaceStyle.canvas)
        let fullViewport = NSView()
        let header = toolbar { [weak parent, weak panel] in
            if let parent, let panel { parent.endSheet(panel) }
        }
        header.heightAnchor.constraint(equalToConstant: 26).isActive = true
        fill(column([header, fullViewport], spacing: 6, alignment: .width), in: surface, inset: 10)
        panel.contentView = surface
        sheet = panel
        page.removeFromSuperview()
        fill(page, in: fullViewport)
        page.fullscreen = true
        updateZoomButtons()
        parent.beginSheet(panel) { [weak self, weak page] _ in
            guard let self else { return }
            sheet = nil
            if zoomButtons.count > 1 { zoomButtons.removeLast() }
            if let page, self.page === page {
                page.removeFromSuperview()
                fill(page, in: viewport)
                page.fullscreen = false
            }
            updateZoomButtons()
            let waiters = collapseWaiters
            collapseWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        return true
    }

    private func collapse() async {
        guard let sheet, let parent = sheet.sheetParent else { return }
        await withCheckedContinuation { continuation in
            let first = collapseWaiters.isEmpty
            collapseWaiters.append(continuation)
            if first { parent.endSheet(sheet) }
        }
    }

    private func loadAppData(_ session: McpAppSession, page: HtmlReplyWebView) {
        Task { [weak self, weak page] in
            async let call = try? session.toolCall()
            async let tool = try? session.toolDefinition()
            if let value = await call, let page, self?.page === page { page.setToolCall(value) }
            if let value = await tool, let page, self?.page === page { page.setToolDefinition(value) }
        }
    }

    private func requireActive(_ page: HtmlReplyWebView, session: McpAppSession) throws {
        guard self.page === page, window != nil, !closingApp else { throw ClientError.message("The app is unavailable.") }
        try session.requireConnection()
    }

    private func handleApp(_ method: String, params: Wire, page: HtmlReplyWebView, session: McpAppSession) async throws -> Wire {
        try requireActive(page, session: session)
        let approval: McpAppSession.Approval = { [weak self, weak page] title, detail in
            guard let self, let page else { throw ClientError.disconnected }
            return try await approve(title, detail: detail, page: page, session: session)
        }
        switch method {
        case "callTool":
            return try await session.callTool(params, approve: approval) { try requireActive(page, session: session) }
        case "readResource":
            return try await session.readResource(params)
        case "updateModelContext":
            return try await session.updateModelContext(params)
        case "sendMessage":
            try await session.send(params, approve: approval) { try requireActive(page, session: session) }
        case "openLink":
            guard page.consumeActivation(), let url = HtmlReplyWebView.linkURL(params["url"].string) else {
                throw ClientError.message("Links open only from a click in the app.")
            }
            NSWorkspace.shared.open(url)
        case "displayMode":
            if params["mode"].string == "inline" { await collapse() }
            else if params["mode"].string == "fullscreen", page.consumeActivation() { expand() }
            return .string(sheet == nil ? "inline" : "fullscreen")
        case "downloadFile":
            try await saveFiles(params["files"].array, page: page, session: session)
        case "size":
            if sheet == nil, let height = params["height"].double, height.isFinite {
                onMetrics?(viewport.bounds.width, zoom, min(McpAppPage.maximumHeight, max(80, height.rounded())))
            }
        case "requestTeardown":
            if sheet != nil { await collapse() }
            else { Task { await stopApp(leftPage: false) } }
        default:
            throw ClientError.invalidResponse
        }
        return .null
    }

    private func approve(_ title: String, detail: String, page: HtmlReplyWebView, session: McpAppSession) async throws -> Bool {
        guard !asking else { throw ClientError.message("Another app request needs your attention.") }
        asking = true
        updateZoomButtons()
        defer { asking = false; updateZoomButtons() }
        await collapse()
        try requireActive(page, session: session)
        guard let parent = window, parent.attachedSheet == nil else {
            throw ClientError.message("T3 could not ask for approval here.")
        }
        let alert = NSAlert()
        alert.messageText = title
        let text = NSTextView()
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = detail
        text.textContainerInset = NSSize(width: 5, height: 4)
        let preview = textScroller(text)
        preview.frame = NSRect(x: 0, y: 0, width: 390, height: 158)
        alert.accessoryView = preview
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        alert.addButton(withTitle: "Allow Once")
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: parent) { result in
                continuation.resume(returning: result == .alertSecondButtonReturn)
            }
        }
    }

    private func saveFiles(_ files: [Wire], page: HtmlReplyWebView, session: McpAppSession) async throws {
        guard !asking else { throw ClientError.message("Another app request needs your attention.") }
        asking = true
        updateZoomButtons()
        defer { asking = false; updateZoomButtons() }
        await collapse()
        for file in files {
            try requireActive(page, session: session)
            guard let parent = window, parent.attachedSheet == nil else { throw ClientError.message("The app could not open a save dialog.") }
            let panel = NSSavePanel()
            panel.title = "Save a file from \(session.page.server)"
            panel.nameFieldStringValue = AttachmentFile.safeName(file["name"].string ?? "download")
            let url: URL? = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: parent) { result in
                    continuation.resume(returning: result == .OK ? panel.url : nil)
                }
            }
            guard let url else { throw ClientError.message("Declined by the user.") }
            try requireActive(page, session: session)
            let data = try await session.downloadBytes(file)
            try requireActive(page, session: session)
            try await Task.detached(priority: .utility) { try data.write(to: url, options: .atomic) }.value
        }
    }

    private func stopApp(leftPage: Bool) async {
        guard let app = reference.app, let page, !closingApp else { return }
        closingApp = true
        updateZoomButtons()
        await collapse()
        if !leftPage { await page.teardown() }
        guard self.page === page else { closingApp = false; updateZoomButtons(); return }
        page.removeFromSuperview()
        self.page = nil
        failed = true
        status.isHidden = false
        status.stringValue = leftPage ? "The \(app.server) app left its page and was stopped." : "The \(app.server) app was closed."
        retry.isHidden = false
        retry.title = "Show App"
        retry.setAccessibilityLabel("Show App")
        closingApp = false
        onMetrics?(viewport.bounds.width, zoom, 96)
        updateZoomButtons()
    }
}
