import AppKit

@MainActor
final class MessageAttachmentsView: NSView {
    static let imageHeight: CGFloat = 118
    static let imageWidth: CGFloat = 136
    static let fileHeight: CGFloat = 28

    static func height(for attachments: [ChatAttachment]) -> CGFloat {
        let images = attachments.filter(\.isImage).count
        let files = attachments.count - images
        return (images == 0 ? 0 : imageHeight) + CGFloat(files) * fileHeight + (images > 0 && files > 0 ? 8 : 0)
    }

    static func width(for attachments: [ChatAttachment], available: CGFloat) -> CGFloat {
        let images = attachments.filter(\.isImage).count
        let imageWidth = CGFloat(images) * Self.imageWidth + CGFloat(max(0, images - 1)) * 8
        let fileWidth: CGFloat = images < attachments.count ? 320 : 0
        return min(available, max(imageWidth, fileWidth))
    }

    init(attachments: [ChatAttachment], store: AttachmentStore, scope: AttachmentScope?,
         onOpen: @escaping (ChatAttachment) -> Void) {
        super.init(frame: .zero)
        let images = attachments.filter(\.isImage)
        let files = attachments.filter { !$0.isImage }
        var sections: [NSView] = []
        if !images.isEmpty {
            let tiles = images.map { AttachmentImageTile(attachment: $0, store: store, scope: scope, onOpen: onOpen) }
            let strip = AttachmentImageStrip(tiles: tiles)
            strip.heightAnchor.constraint(equalToConstant: Self.imageHeight).isActive = true
            sections.append(strip)
        }
        if !files.isEmpty {
            let rows = files.map { file -> NSView in
                let open = ActionButton(file.name, symbol: file.isSupported ? "doc" : "questionmark.square.dashed", style: .subtle) {
                    onOpen(file)
                }
                open.alignment = .left
                open.cell?.lineBreakMode = .byTruncatingMiddle
                open.font = .systemFont(ofSize: 12)
                open.isEnabled = file.isSupported && scope != nil
                open.toolTip = file.isSupported ? "Preview \(file.name)" : "This attachment type needs a newer client."
                open.setAccessibilityLabel("Preview \(file.name)")
                let size = label(file.sizeLabel, size: 10.5, color: WorkspaceStyle.muted)
                size.setContentCompressionResistancePriority(.required, for: .horizontal)
                let line = row([open, NSView(), size], spacing: 6)
                line.heightAnchor.constraint(equalToConstant: Self.fileHeight).isActive = true
                return line
            }
            sections.append(column(rows, spacing: 0, alignment: .width))
        }
        fill(column(sections, spacing: 8, alignment: .width), in: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
private final class AttachmentImageStrip: NSScrollView {
    private let tiles: [AttachmentImageTile]
    private var observers: [NSObjectProtocol] = []

    init(tiles: [AttachmentImageTile]) {
        self.tiles = tiles
        super.init(frame: .zero)
        drawsBackground = false
        hasHorizontalScroller = true
        hasVerticalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        automaticallyAdjustsContentInsets = false
        let document = row(tiles, spacing: 8)
        document.translatesAutoresizingMaskIntoConstraints = false
        documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: contentView.topAnchor),
            document.heightAnchor.constraint(equalTo: contentView.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if window != nil {
            var ancestor: NSView? = contentView
            while let view = ancestor {
                if let clip = view as? NSClipView {
                    clip.postsBoundsChangedNotifications = true
                    observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                            object: clip, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.updateVisibleImages() }
                    })
                }
                ancestor = view.superview
            }
        }
        updateVisibleImages()
    }

    override func layout() {
        super.layout()
        updateVisibleImages()
    }

    private func updateVisibleImages() {
        guard window != nil, !visibleRect.isEmpty, let document = documentView,
              contentView.bounds.width > 0, document.bounds.width > 0 else {
            for tile in tiles { tile.setVisible(false) }
            return
        }
        document.layoutSubtreeIfNeeded()
        let visible = documentVisibleRect
        for tile in tiles {
            let frame = document.convert(tile.bounds, from: tile)
            tile.setVisible(visible.intersects(frame))
        }
    }
}

@MainActor
private final class AttachmentImageTile: NSView {
    private let attachment: ChatAttachment
    private let store: AttachmentStore
    private let scope: AttachmentScope?
    private let onOpen: (ChatAttachment) -> Void
    private let button = NSButton()
    private var task: Task<Void, Never>?
    private var loaded = false
    private var failed = false

    init(attachment: ChatAttachment, store: AttachmentStore, scope: AttachmentScope?,
         onOpen: @escaping (ChatAttachment) -> Void) {
        self.attachment = attachment
        self.store = store
        self.scope = scope
        self.onOpen = onOpen
        super.init(frame: .zero)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyUpOrDown
        button.image = WorkspaceStyle.symbol("photo", size: 22)
        button.contentTintColor = WorkspaceStyle.muted
        button.target = self
        button.action = #selector(open)
        button.isEnabled = scope != nil
        button.setAccessibilityLabel("Preview \(attachment.name)")
        button.toolTip = attachment.name
        let picture = Surface(WorkspaceStyle.bubble, border: WorkspaceStyle.outline, radius: 8)
        picture.heightAnchor.constraint(equalToConstant: 96).isActive = true
        fill(button, in: picture, inset: 4)
        let name = label(attachment.name, size: 10.5, color: WorkspaceStyle.secondary)
        name.lineBreakMode = .byTruncatingMiddle
        name.toolTip = attachment.name
        name.heightAnchor.constraint(equalToConstant: 16).isActive = true
        fill(column([picture, name], spacing: 6, alignment: .width), in: self)
        widthAnchor.constraint(equalToConstant: MessageAttachmentsView.imageWidth).isActive = true
        heightAnchor.constraint(equalToConstant: MessageAttachmentsView.imageHeight).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setVisible(_ visible: Bool) {
        if !visible { task?.cancel(); task = nil; return }
        guard task == nil, !loaded, !failed, let scope else { return }
        let store = store
        let attachment = attachment
        task = Task { [weak self] in
            do {
                let image = try await store.thumbnail(attachment, scope: scope)
                try Task.checkCancellation()
                guard let self else { return }
                button.image = image
                button.contentTintColor = nil
                loaded = true
            } catch {
                guard !Task.isCancelled, let self else { return }
                button.image = WorkspaceStyle.symbol("exclamationmark.triangle", size: 18)
                button.toolTip = "\(attachment.name) · \(error.localizedDescription)"
                failed = true
            }
            self?.task = nil
        }
    }

    @objc private func open() { onOpen(attachment) }
}
