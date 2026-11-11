import AVFoundation
import CoreText
import Foundation

actor BrowserRecordingEncoder {
    private struct Output {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let width: Int
        let height: Int
    }

    private struct Cues: Equatable {
        let press: CGPoint?
        let shortcut: String?
    }

    private let directory: URL
    private let destination: URL
    private let partial: URL
    private let preferences: BrowserRecordingPreferences
    private var output: Output?
    private var sampleTask: Task<Void, Never>?
    private var latestImage: CGImage?
    private var cachedPixels: CVPixelBuffer?
    private var cachedCues: Cues?
    private var viewport = CGSize.zero
    private var press: (point: CGPoint, expires: ContinuousClock.Instant)?
    private var shortcut: (label: String, expires: ContinuousClock.Instant)?
    private var startTime: UInt64 = 0
    private var lastFrame: Int64 = -1
    private(set) var receivedStreamFrame = false

    init(directory: URL, preferences: BrowserRecordingPreferences) {
        self.directory = directory
        self.preferences = preferences
        let id = UUID()
        destination = BrowserMediaFiles.destination(in: directory, prefix: "Browser Recording", extension: "mp4", id: id)
        partial = directory.appendingPathComponent(".t3-recording-\(id.uuidString.lowercased()).mp4")
    }

    func start(with image: CGImage, onFailure: @escaping @Sendable (String) -> Void) throws {
        guard output == nil else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let scale = min(1, 1_920.0 / Double(image.width), 1_200.0 / Double(image.height))
            let width = max(2, Int(Double(image.width) * scale) / 2 * 2)
            let height = max(2, Int(Double(image.height) * scale) / 2 * 2)
            let rate = preferences.frameRate.rawValue
            let bitRate = max(500_000, min(6_000_000, width * height * rate / 15))
            let writer = try AVAssetWriter(outputURL: partial, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = true
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitRate,
                    AVVideoExpectedSourceFrameRateKey: rate,
                    AVVideoMaxKeyFrameIntervalKey: rate * 2,
                ],
            ])
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ])
            guard writer.canAdd(input) else { throw ClientError.message("The Mac could not configure the video encoder.") }
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? ClientError.message("The video encoder could not start.") }
            writer.startSession(atSourceTime: .zero)
            output = .init(writer: writer, input: input, adaptor: adaptor, width: width, height: height)
            latestImage = image
            startTime = DispatchTime.now().uptimeNanoseconds
            try append(at: 0)
            guard lastFrame == 0 else { throw ClientError.message("The video encoder could not accept the first frame.") }
        } catch {
            discard()
            throw error
        }
        let interval = Duration.nanoseconds(1_000_000_000 / preferences.frameRate.rawValue)
        sampleTask = Task { [weak self] in
            let clock = ContinuousClock()
            var deadline = clock.now.advanced(by: interval)
            while !Task.isCancelled {
                do { try await clock.sleep(until: deadline) } catch { return }
                guard let self, !Task.isCancelled else { return }
                do { try await self.appendCurrentFrame() }
                catch {
                    await self.discard()
                    onFailure(error.localizedDescription)
                    return
                }
                let advanced = deadline.advanced(by: interval)
                let now = clock.now
                deadline = advanced > now ? advanced : now.advanced(by: interval)
            }
        }
    }

    func offer(_ image: CGImage) {
        receivedStreamFrame = true
        latestImage = image
        cachedPixels = nil
    }

    func setViewport(_ size: CGSize) { viewport = size }

    func markAgentClick(x: Double, y: Double) {
        if let point = BrowserRecordingInput.normalizedPoint(x: x, y: y, viewport: viewport) { markPress(point) }
    }

    func markPress(_ point: CGPoint) {
        guard preferences.showMousePresses else { return }
        press = (point, ContinuousClock.now.advanced(by: .milliseconds(450)))
    }

    func markShortcut(_ label: String) {
        guard preferences.showShortcuts else { return }
        shortcut = (label, ContinuousClock.now.advanced(by: .milliseconds(850)))
    }

    func finish() async throws -> URL {
        sampleTask?.cancel()
        sampleTask = nil
        guard let output, lastFrame >= 0 else { throw ClientError.message("The recording captured no frames.") }
        do {
            let end = max(lastFrame + 1, frameIndex() + 1)
            try append(at: end - 1)
            output.writer.endSession(atSourceTime: CMTime(value: end, timescale: Int32(preferences.frameRate.rawValue)))
            output.input.markAsFinished()
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                output.writer.finishWriting { done.resume() }
            }
            guard output.writer.status == .completed else {
                throw output.writer.error ?? ClientError.message("The browser recording could not be finalized.")
            }
            try FileManager.default.moveItem(at: partial, to: destination)
            self.output = nil
            latestImage = nil
            cachedPixels = nil
            return destination
        } catch {
            discard()
            throw error
        }
    }

    private func discard() {
        sampleTask?.cancel()
        sampleTask = nil
        if output?.writer.status == .writing { output?.writer.cancelWriting() }
        output = nil
        latestImage = nil
        cachedPixels = nil
        try? FileManager.default.removeItem(at: partial)
    }

    private func frameIndex() -> Int64 {
        let elapsed = DispatchTime.now().uptimeNanoseconds - startTime
        return Int64(Double(elapsed) * Double(preferences.frameRate.rawValue) / 1_000_000_000)
    }

    private func appendCurrentFrame() throws { try append(at: frameIndex()) }

    private func append(at index: Int64) throws {
        guard let output, index > lastFrame else { return }
        guard output.writer.status == .writing else {
            throw output.writer.error ?? ClientError.message("The browser video encoder stopped.")
        }
        guard output.input.isReadyForMoreMediaData else { return }
        let now = ContinuousClock.now
        let cues = Cues(press: press.flatMap { $0.expires > now ? $0.point : nil },
                        shortcut: shortcut.flatMap { $0.expires > now ? $0.label : nil })
        let pixels = try pixels(output: output, cues: cues)
        let time = CMTime(value: index, timescale: Int32(preferences.frameRate.rawValue))
        guard output.adaptor.append(pixels, withPresentationTime: time) else {
            throw output.writer.error ?? ClientError.message("The video encoder rejected a browser frame.")
        }
        lastFrame = index
    }

    private func pixels(output: Output, cues: Cues) throws -> CVPixelBuffer {
        if let cachedPixels, cachedCues == cues { return cachedPixels }
        guard let image = latestImage, let pool = output.adaptor.pixelBufferPool else {
            throw ClientError.message("The browser frame is unavailable.")
        }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess, let buffer,
              CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            throw ClientError.message("The video encoder could not allocate a frame.")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: output.width, height: output.height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                                        CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            throw ClientError.message("The browser frame could not be rendered into the recording.")
        }
        let canvas = CGRect(x: 0, y: 0, width: output.width, height: output.height)
        let content = AVMakeRect(aspectRatio: CGSize(width: image.width, height: image.height), insideRect: canvas)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(canvas)
        context.interpolationQuality = .high
        context.draw(image, in: content)
        if let press = cues.press {
            let radius = min(18, max(7, min(canvas.width, canvas.height) * 0.035))
            let point = CGPoint(x: content.minX + press.x * content.width, y: content.maxY - press.y * content.height)
            let circle = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            context.setFillColor(CGColor(red: 1, green: 0.68, blue: 0.38, alpha: 0.24))
            context.fillEllipse(in: circle)
            context.setStrokeColor(CGColor(red: 1, green: 0.68, blue: 0.38, alpha: 0.95))
            context.setLineWidth(max(2, radius * 0.14))
            context.strokeEllipse(in: circle)
        }
        if let shortcut = cues.shortcut { drawShortcut(shortcut, in: canvas, context: context) }
        cachedPixels = buffer
        cachedCues = cues
        return buffer
    }

    private func drawShortcut(_ shortcut: String, in canvas: CGRect, context: CGContext) {
        let size = min(28, max(12, canvas.height * 0.046))
        let font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: shortcut, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let box = CGRect(x: canvas.midX - width / 2 - size * 0.55, y: size * 0.65,
                         width: width + size * 1.1, height: size * 1.55)
        context.setFillColor(CGColor(gray: 0.07, alpha: 0.86))
        context.addPath(CGPath(roundedRect: box, cornerWidth: size * 0.32, cornerHeight: size * 0.32, transform: nil))
        context.fillPath()
        context.textPosition = CGPoint(x: canvas.midX - width / 2, y: box.minY + size * 0.48)
        CTLineDraw(line, context)
    }
}
