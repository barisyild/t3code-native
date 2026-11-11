import AppKit

@MainActor
final class BrowserRegionEditor: NSWindowController, NSTextViewDelegate {
    private let snapshot: BrowserSnapshot
    private let selection: BrowserRegionSelectionView
    private let comment = NSTextView()
    private let measurement = label("Drag to mark a region", size: 11.5, color: WorkspaceStyle.muted)
    private let status = label(size: 11.5, color: WorkspaceStyle.negative)
    private let onAttach: (PickedAttachment) throws -> Void
    private var task: Task<Void, Never>?
    private lazy var wholeImage = ActionButton("Select Full Screenshot", style: .subtle) { [weak self] in self?.selection.selectAll(nil) }
    private lazy var attach = ActionButton("Attach Region to Draft", symbol: "paperclip", style: .subtle) { [weak self] in self?.submit() }
    private lazy var cancel = ActionButton("Cancel", style: .subtle) { [weak self] in self?.closeSheet() }
    var onClose: (() -> Void)?

    init(snapshot: BrowserSnapshot, onAttach: @escaping (PickedAttachment) throws -> Void) {
        self.snapshot = snapshot
        self.onAttach = onAttach
        selection = BrowserRegionSelectionView(image: snapshot.image)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 675, height: 570),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Annotate Browser Region"
        window.contentMinSize = NSSize(width: 440, height: 340)
        window.isReleasedWhenClosed = false
        let surface = Surface(WorkspaceStyle.navigation)
        window.contentView = surface
        let subject = label(snapshot.target.title, size: 14, weight: .semibold, color: WorkspaceStyle.ink)
        subject.toolTip = snapshot.target.title
        selection.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        selection.onChange = { [weak self] in self?.render() }
        comment.font = .systemFont(ofSize: 13)
        comment.textColor = WorkspaceStyle.ink
        comment.insertionPointColor = WorkspaceStyle.ink
        comment.textContainerInset = NSSize(width: 7, height: 5)
        comment.delegate = self
        comment.setAccessibilityLabel("Browser Annotation Note")
        let note = Surface(WorkspaceStyle.canvas, border: WorkspaceStyle.outline, radius: 7)
        fill(textScroller(comment, editable: true), in: note, inset: 1)
        note.heightAnchor.constraint(equalToConstant: 62).isActive = true
        cancel.keyEquivalent = "\u{1b}"
        attach.keyEquivalent = "\r"
        attach.keyEquivalentModifierMask = .command
        let footer = row([wholeImage, NSView(), cancel, attach], spacing: 8)
        fill(column([row([subject, NSView(), measurement]), selection,
                     label("Note", size: 11.5, color: WorkspaceStyle.muted), note, status, footer],
                    spacing: 8, alignment: .width), in: surface, inset: 14)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(in parent: NSWindow) {
        guard let window, parent.attachedSheet == nil else { return }
        parent.beginSheet(window) { [weak self] _ in
            self?.task?.cancel()
            self?.onClose?()
        }
    }

    func textDidChange(_ notification: Notification) {
        status.stringValue = ""
        render()
    }

    private func render() {
        let pixels = selection.region.flatMap {
            BrowserImageCapture.pixelRect($0, width: snapshot.image.width, height: snapshot.image.height)
        }
        measurement.stringValue = pixels.map { "\(Int($0.width)) × \(Int($0.height)) px" } ?? "Drag to mark a region"
        let valid = comment.string.utf16.count <= BrowserRegionAnnotation.maximumCommentLength
        if !valid { status.stringValue = "Keep the note within 8,000 characters." }
        status.isHidden = status.stringValue.isEmpty
        attach.isEnabled = pixels != nil && valid && task == nil
        wholeImage.isEnabled = task == nil
        selection.isSelectingEnabled = task == nil
        comment.isEditable = task == nil
    }

    private func submit() {
        guard attach.isEnabled, let region = selection.region else { return }
        let snapshot = snapshot
        let text = comment.string
        status.stringValue = "Preparing region…"
        status.textColor = WorkspaceStyle.muted
        task = Task { [weak self] in
            do {
                let file = try await BrowserImageCapture.region(snapshot, selection: region, comment: text)
                try Task.checkCancellation()
                guard let self else { return }
                try onAttach(file)
                closeSheet()
            } catch {
                guard let self, !Task.isCancelled else { return }
                task = nil
                status.stringValue = error.localizedDescription
                status.textColor = WorkspaceStyle.negative
                render()
            }
        }
        render()
    }

    private func closeSheet() {
        task?.cancel()
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
    }
}

@MainActor
private final class BrowserRegionSelectionView: NSView {
    private let image: NSImage
    private var anchor: CGPoint?
    private(set) var region: CGRect?
    var onChange: (() -> Void)?
    var isSelectingEnabled = true

    init(image: CGImage) {
        self.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Browser Region Selection")
        setAccessibilityHelp("Drag to select a region or choose Select Full Screenshot.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    private var imageBounds: CGRect { BrowserViewport.fit(image.size, in: bounds.insetBy(dx: 4, dy: 4)) }

    override func draw(_ dirtyRect: NSRect) {
        WorkspaceStyle.canvas.setFill()
        bounds.fill()
        let imageBounds = imageBounds
        image.draw(in: imageBounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        guard let region else { return }
        let selection = CGRect(x: imageBounds.minX + region.minX * imageBounds.width,
                               y: imageBounds.minY + region.minY * imageBounds.height,
                               width: region.width * imageBounds.width, height: region.height * imageBounds.height)
        let shade = NSBezierPath(rect: imageBounds)
        shade.appendRect(selection)
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.47).setFill()
        shade.fill()
        WorkspaceStyle.modelFocus.setStroke()
        let outline = NSBezierPath(rect: selection)
        outline.lineWidth = 2
        outline.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard isSelectingEnabled, let point = normalized(event, clamp: false) else { return }
        anchor = point
        changeRegion(nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isSelectingEnabled, let anchor, let point = normalized(event, clamp: true) else { return }
        let rect = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                          width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
        changeRegion(rect.isEmpty ? nil : rect)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        anchor = nil
    }

    override func selectAll(_ sender: Any?) {
        if isSelectingEnabled { changeRegion(CGRect(x: 0, y: 0, width: 1, height: 1)) }
    }

    private func normalized(_ event: NSEvent, clamp: Bool) -> CGPoint? {
        let area = imageBounds
        let point = convert(event.locationInWindow, from: nil)
        guard !area.isEmpty, clamp || area.contains(point) else { return nil }
        return CGPoint(x: min(1, max(0, (point.x - area.minX) / area.width)),
                       y: min(1, max(0, (point.y - area.minY) / area.height)))
    }

    private func changeRegion(_ next: CGRect?) {
        guard region != next else { return }
        region = next
        needsDisplay = true
        onChange?()
    }
}
