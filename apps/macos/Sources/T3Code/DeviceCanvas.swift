import AppKit
@preconcurrency import AVFoundation

@MainActor
final class DeviceCanvas: NSView {
    private let still = CALayer()
    private let video = AVSampleBufferDisplayLayer()
    private var sourceSize = CGSize.zero
    private var displayRect = CGRect.zero
    private var screen: DeviceScreenConfig?
    private var waitingForKey = true
    private var pressed = Set<Int>()
    private var pointer: CGPoint?
    private var usingWebRTC = false
    var avcc = true
    var platform = DevicePlatform.ios
    var acceptsInput = false {
        didSet { if !acceptsInput { pointer = nil; pressed.removeAll() } }
    }
    var onInput: ((DeviceInput) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        video.videoGravity = .resizeAspect
        still.contentsGravity = .resizeAspect
        layer?.addSublayer(video)
        layer?.addSublayer(still)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Device screen")
        setAccessibilityHelp("Click the device screen to send touch and keyboard input.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { acceptsInput }

    func configure(_ screen: DeviceScreenConfig) {
        if self.screen?.orientation != screen.orientation { finishTouch() }
        self.screen = screen
        needsLayout = true
    }

    func display(_ image: CGImage) {
        sourceSize = CGSize(width: image.width, height: image.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        still.contents = image
        still.isHidden = false
        CATransaction.commit()
        needsLayout = true
    }

    func display(_ sample: DeviceVideoSample) -> Bool {
        let renderer = video.sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding || renderer.status == .failed || !renderer.isReadyForMoreMediaData {
            resetVideo(removeImage: false)
        }
        guard !waitingForKey || sample.keyframe, renderer.isReadyForMoreMediaData else { return false }
        renderer.enqueue(sample.buffer)
        waitingForKey = false
        if sourceSize != sample.size {
            sourceSize = sample.size
            needsLayout = true
        }
        still.isHidden = true
        return true
    }

    func resetVideo(removeImage: Bool) {
        video.sampleBufferRenderer.flush(removingDisplayedImage: removeImage, completionHandler: nil)
        waitingForKey = true
    }

    func setWebRTC(_ enabled: Bool, size: CGSize = .zero) {
        usingWebRTC = enabled
        layer?.backgroundColor = enabled ? NSColor.clear.cgColor : NSColor.black.cgColor
        video.isHidden = enabled
        still.isHidden = enabled
        if enabled {
            sourceSize = size
            needsLayout = true
        }
    }

    func reset() {
        finishTouch()
        screen = nil
        sourceSize = .zero
        displayRect = .zero
        still.contents = nil
        resetVideo(removeImage: true)
        setWebRTC(false)
        acceptsInput = false
    }

    override func layout() {
        super.layout()
        guard sourceSize.width > 0, sourceSize.height > 0 else { return }
        let angle: CGFloat
        if !usingWebRTC, platform == .ios, sourceSize.width <= sourceSize.height, let screen, screen.size.width <= screen.size.height {
            switch screen.orientation {
            case .portrait: angle = 0
            case .left: angle = .pi / 2
            case .right: angle = -.pi / 2
            case .upsideDown: angle = .pi
            }
        } else { angle = 0 }
        let turned = abs(angle) == .pi / 2
        let fitted = turned ? CGSize(width: sourceSize.height, height: sourceSize.width) : sourceSize
        displayRect = AVMakeRect(aspectRatio: fitted, insideRect: bounds)
        let layerSize = turned ? CGSize(width: displayRect.height, height: displayRect.width) : displayRect.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [video, still] {
            layer.bounds = CGRect(origin: .zero, size: layerSize)
            layer.position = CGPoint(x: displayRect.midX, y: displayRect.midY)
            layer.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        }
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        guard let point = point(event, clamp: false) else { return }
        window?.makeFirstResponder(self)
        pointer = point
        onInput?(.touch(.begin, point))
    }

    override func mouseDragged(with event: NSEvent) {
        guard pointer != nil, let point = point(event, clamp: true) else { return }
        pointer = point
        onInput?(.touch(.move, point))
    }

    override func mouseUp(with event: NSEvent) {
        if pointer != nil { pointer = point(event, clamp: true) ?? pointer }
        finishTouch()
    }

    private func finishTouch() {
        if let pointer { onInput?(.touch(.end, pointer)) }
        pointer = nil
    }

    private func point(_ event: NSEvent, clamp: Bool) -> CGPoint? {
        guard acceptsInput, displayRect.width > 0, displayRect.height > 0 else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        guard clamp || displayRect.contains(local) else { return nil }
        return CGPoint(x: min(1, max(0, (local.x - displayRect.minX) / displayRect.width)),
                       y: min(1, max(0, (local.y - displayRect.minY) / displayRect.height)))
    }

    override func keyDown(with event: NSEvent) {
        guard acceptsInput else { return }
        if avcc {
            guard let usage = Self.hidKeys[event.keyCode], pressed.insert(usage).inserted else { return }
            onInput?(.hid(usage, down: true))
        } else if event.keyCode == 53 {
            onInput?(.button(.back))
        } else if let code = Self.androidKeys[event.keyCode] {
            onInput?(.key(code))
        } else if event.modifierFlags.intersection([.command, .control]).isEmpty, let text = event.characters, !text.isEmpty {
            onInput?(.text(text))
        }
    }

    override func keyUp(with event: NSEvent) {
        guard avcc, let usage = Self.hidKeys[event.keyCode], pressed.remove(usage) != nil else { return }
        onInput?(.hid(usage, down: false))
    }

    override func flagsChanged(with event: NSEvent) {
        guard acceptsInput, avcc, let (usage, flag) = Self.modifiers[event.keyCode] else { return }
        if event.modifierFlags.contains(flag), pressed.insert(usage).inserted {
            onInput?(.hid(usage, down: true))
        } else if pressed.remove(usage) != nil {
            onInput?(.hid(usage, down: false))
        }
    }

    override func resignFirstResponder() -> Bool {
        finishTouch()
        for usage in pressed { onInput?(.hid(usage, down: false)) }
        pressed.removeAll()
        return super.resignFirstResponder()
    }

    @objc func paste(_ sender: Any?) {
        guard acceptsInput, !avcc, let text = NSPasteboard.general.string(forType: .string) else { return }
        onInput?(.text(text))
    }

    private static let hidKeys: [UInt16: Int] = {
        let alphabet: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
        let numbers: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        var keys = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($0.element, $0.offset + 4) })
        for (index, key) in numbers.enumerated() { keys[key] = 30 + index }
        keys.merge([36: 40, 76: 88, 53: 41, 51: 42, 48: 43, 49: 44, 27: 45, 24: 46, 33: 47, 30: 48,
                    42: 49, 41: 51, 39: 52, 50: 53, 43: 54, 47: 55, 44: 56, 115: 74, 116: 75,
                    117: 76, 119: 77, 121: 78, 124: 79, 123: 80, 125: 81, 126: 82]) { _, special in special }
        return keys
    }()

    private static let modifiers: [UInt16: (Int, NSEvent.ModifierFlags)] = [
        59: (224, .control), 56: (225, .shift), 58: (226, .option), 55: (227, .command),
        62: (228, .control), 60: (229, .shift), 61: (230, .option), 54: (231, .command),
    ]
    private static let androidKeys = [UInt16(126): 19, 125: 20, 123: 21, 124: 22, 48: 61, 36: 66, 76: 66,
                                      51: 67, 117: 112, 115: 122, 119: 123, 116: 92, 121: 93]
}
