import AVFoundation
import Foundation

final class VoicePCMConverter {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat

    init(input: AVAudioFormat) throws {
        guard input.sampleRate.isFinite, input.sampleRate > 0, input.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(VoicePCM.sampleRate),
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else {
            throw ClientError.message("The microphone audio format is unavailable.")
        }
        self.output = output
        self.converter = converter
        converter.primeMethod = .none
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> Data {
        guard input.format == converter.inputFormat else { throw ClientError.message("The microphone audio format changed.") }
        guard input.frameLength > 0 else { return Data() }
        let frames = ceil(Double(input.frameLength) * output.sampleRate / input.format.sampleRate) + 16
        guard frames <= Double(UInt32.max), let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: UInt32(frames)) else {
            throw ClientError.invalidResponse
        }
        let source = ConverterInput(input)
        var error: NSError?
        let result = converter.convert(to: buffer, error: &error) { requested, status in source.next(requested, status) }
        guard result != .error, source.consumedAll, let samples = buffer.floatChannelData?[0] else {
            throw ClientError.message(error?.localizedDescription ?? "Couldn’t convert microphone audio.")
        }
        return Data(bytes: samples, count: Int(buffer.frameLength) * VoicePCM.bytesPerSample)
    }

    // AVAudioConverter calls the supplier synchronously for one conversion.
    private final class ConverterInput: @unchecked Sendable {
        private let buffer: AVAudioPCMBuffer
        private var slice: AVAudioPCMBuffer?
        private var offset: AVAudioFrameCount = 0

        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

        var consumedAll: Bool { offset == buffer.frameLength }

        func next(_ requested: AVAudioPacketCount, _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            status.pointee = .noDataNow
            let frames = min(requested, buffer.frameLength - offset)
            guard frames > 0 else { return nil }
            if offset == 0 && frames == buffer.frameLength {
                offset = frames
                status.pointee = .haveData
                return buffer
            }
            if slice == nil { slice = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: frames) }
            guard let slice else { return nil }
            let count = min(frames, slice.frameCapacity)
            let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
            let input = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let output = UnsafeMutableAudioBufferListPointer(slice.mutableAudioBufferList)
            guard bytesPerFrame > 0, input.count == output.count else { return nil }
            slice.frameLength = count
            for index in input.indices {
                guard let source = input[index].mData, let destination = output[index].mData else { return nil }
                destination.copyMemory(from: source.advanced(by: Int(offset) * bytesPerFrame), byteCount: Int(count) * bytesPerFrame)
            }
            offset += count
            status.pointee = .haveData
            return slice
        }
    }
}

@MainActor
final class VoiceRecording {
    let audio: AsyncThrowingStream<Data, Error>
    private var stopCapture: (() -> Void)?

    init(audio: AsyncThrowingStream<Data, Error>, stop: @escaping () -> Void) {
        self.audio = audio
        stopCapture = stop
    }

    func stop() {
        let stop = stopCapture
        stopCapture = nil
        stop?()
    }

    static func microphone() async throws -> VoiceRecording {
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: allowed = true
        case .notDetermined:
            guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
                throw ClientError.message("Open the T3 Code AppKit application to use the microphone.")
            }
            allowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: allowed = false
        }
        try Task.checkCancellation()
        guard allowed else { throw ClientError.message("Allow T3 Code to use the microphone in System Settings.") }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let (audio, output) = AsyncThrowingStream<Data, Error>.makeStream()
        let producer = VoiceAudioProducer(converter: try VoicePCMConverter(input: format), output: output)
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { @Sendable buffer, _ in producer.append(buffer) }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            producer.finish()
            throw error
        }
        let observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
            producer.finish(error: ClientError.message("The microphone changed during dictation. Record again to continue."))
        }
        return VoiceRecording(audio: audio) {
            NotificationCenter.default.removeObserver(observer)
            input.removeTap(onBus: 0)
            engine.stop()
            producer.finish()
        }
    }
}

// The tap and stop path share the converter and its bounded audio buffer under one lock.
private final class VoiceAudioProducer: @unchecked Sendable {
    private let converter: VoicePCMConverter
    private let output: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var pending = Data()
    private var remaining = VoicePCM.recordingLimit
    private var ended = false

    init(converter: VoicePCMConverter, output: AsyncThrowingStream<Data, Error>.Continuation) {
        self.converter = converter
        self.output = output
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !ended else { return }
        do {
            let data = try converter.convert(buffer)
            let accepted = min(remaining, data.count)
            pending.append(data.prefix(accepted))
            remaining -= accepted
            let chunk = VoicePCM.chunkLimit / 2
            while pending.count >= chunk {
                output.yield(Data(pending.prefix(chunk)))
                pending.removeFirst(chunk)
            }
            if remaining == 0 { close() }
        } catch { close(error: error) }
    }

    func finish(error: Error? = nil) {
        lock.lock()
        defer { lock.unlock() }
        close(error: error)
    }

    private func close(error: Error? = nil) {
        guard !ended else { return }
        ended = true
        if error == nil, !pending.isEmpty { output.yield(pending) }
        pending.removeAll()
        output.finish(throwing: error)
    }
}
