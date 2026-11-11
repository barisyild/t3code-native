import Foundation
@preconcurrency import CoreMedia

struct DeviceAVCCReader {
    enum Kind: UInt8 { case description = 1, keyframe, delta, seed }

    struct Frame {
        let kind: Kind
        let bytes: Data
    }

    private var buffer = Data()
    private let limit = 8 * 1024 * 1024

    mutating func append(_ bytes: Data) throws -> [Frame] {
        buffer.append(bytes)
        var frames: [Frame] = []
        var cursor = buffer.startIndex
        while buffer.endIndex - cursor >= 4 {
            let size = buffer[cursor..<(cursor + 4)].reduce(0) { ($0 << 8) | Int($1) }
            guard (1...limit).contains(size) else { throw DeviceMediaFailure.invalidFrame }
            guard buffer.endIndex - cursor - 4 >= size else { break }
            let end = cursor + 4 + size
            if let kind = Kind(rawValue: buffer[cursor + 4]) {
                frames.append(.init(kind: kind, bytes: Data(buffer[(cursor + 5)..<end])))
            }
            cursor = end
        }
        if cursor > buffer.startIndex { buffer.removeFirst(cursor - buffer.startIndex) }
        guard buffer.count <= limit + 4 else { throw DeviceMediaFailure.invalidFrame }
        return frames
    }
}

struct DeviceJPEGReader {
    private var buffer = Data()
    private let delimiter: Data?
    private let headerEnd = Data("\r\n\r\n".utf8)
    private let lineEnd = Data("\r\n".utf8)
    private let imageEnd = Data([0xff, 0xd9])
    private let limit = 8 * 1024 * 1024

    init?(contentType: String?) {
        guard let contentType else { return nil }
        if contentType.lowercased().hasPrefix("image/jpeg") {
            delimiter = nil
            return
        }
        guard contentType.lowercased().hasPrefix("multipart/"),
              let parameter = contentType.split(separator: ";").dropFirst().first(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("boundary=")
        }) else { return nil }
        let value = parameter.trimmingCharacters(in: .whitespaces).dropFirst("boundary=".count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !value.isEmpty, value.utf8.count <= 100, value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        delimiter = Data(("--" + value).utf8)
    }

    mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        // URLSession can deliver each multipart image as a separate HTTP response.
        guard let delimiter else {
            guard buffer.count <= limit else { throw DeviceMediaFailure.invalidFrame }
            guard buffer.suffix(imageEnd.count).elementsEqual(imageEnd) else { return [] }
            let frame = buffer
            buffer = Data()
            return [frame]
        }
        var frames: [Data] = []
        while let start = buffer.range(of: delimiter) {
            if start.lowerBound > buffer.startIndex { buffer.removeFirst(start.lowerBound - buffer.startIndex) }
            guard let header = buffer.range(of: headerEnd) else { break }
            guard header.lowerBound - buffer.startIndex <= 4_096 else { throw DeviceMediaFailure.invalidFrame }
            let headers = String(decoding: buffer[..<header.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let length = headers.first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }
            let end: Int
            if let length {
                guard (1...limit).contains(length) else { throw DeviceMediaFailure.invalidFrame }
                end = header.upperBound + length
                guard end <= buffer.endIndex else { break }
            } else {
                guard let next = buffer.range(of: delimiter, in: header.upperBound..<buffer.endIndex) else { break }
                let before = next.lowerBound - lineEnd.count
                end = before >= header.upperBound && buffer[before..<next.lowerBound].elementsEqual(lineEnd)
                    ? before : next.lowerBound
                guard end - header.upperBound <= limit else { throw DeviceMediaFailure.invalidFrame }
            }
            if end > header.upperBound { frames.append(Data(buffer[header.upperBound..<end])) }
            buffer.removeFirst(end - buffer.startIndex)
        }
        guard buffer.count <= limit + 4_096 else { throw DeviceMediaFailure.invalidFrame }
        return frames
    }
}

struct DeviceVideoSample: @unchecked Sendable {
    // CoreMedia copies the bytes into the buffer and no writer uses it after construction.
    let buffer: CMSampleBuffer
    let size: CGSize
    let keyframe: Bool
}

struct DeviceH264 {
    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?
    private var waitingForKey = true

    mutating func describeAVCC(_ bytes: Data) throws {
        let bytes = [UInt8](bytes)
        guard bytes.count >= 8, bytes[0] == 1 else { throw DeviceMediaFailure.invalidFrame }
        let lengthSize = Int(bytes[4] & 3) + 1
        var index = 6
        func parameterSets(_ count: Int) throws -> [Data] {
            var sets: [Data] = []
            for _ in 0..<count {
                guard index + 2 <= bytes.count else { throw DeviceMediaFailure.invalidFrame }
                let size = (Int(bytes[index]) << 8) | Int(bytes[index + 1])
                index += 2
                guard size > 0, index + size <= bytes.count else { throw DeviceMediaFailure.invalidFrame }
                sets.append(Data(bytes[index..<(index + size)]))
                index += size
            }
            return sets
        }
        let sequences = try parameterSets(Int(bytes[5] & 31))
        guard index < bytes.count else { throw DeviceMediaFailure.invalidFrame }
        let pictureCount = Int(bytes[index])
        index += 1
        let pictures = try parameterSets(pictureCount)
        guard let sps = sequences.first, let pps = pictures.first else { throw DeviceMediaFailure.invalidFrame }
        try configure(sps: sps, pps: pps, lengthSize: lengthSize)
    }

    mutating func annexB(_ packet: Data) throws -> DeviceVideoSample? {
        let raw = [UInt8](packet)
        let start = raw.count > 16 && raw[0...3].elementsEqual([0x53, 0x45, 0x4d, 0x55]) && raw[4] == 1 ? 16 : 0
        var offsets: [(prefix: Int, payload: Int)] = []
        var index = start
        while index + 2 < raw.count {
            if raw[index] == 0 && raw[index + 1] == 0 {
                let length = raw[index + 2] == 1 ? 3 :
                    index + 3 < raw.count && raw[index + 2] == 0 && raw[index + 3] == 1 ? 4 : 0
                if length > 0 {
                    offsets.append((index, index + length))
                    index += length
                    continue
                }
            }
            index += 1
        }
        var key = false
        var picture = false
        var encoded = Data()
        for (index, offset) in offsets.enumerated() {
            let end = index + 1 < offsets.count ? offsets[index + 1].prefix : raw.count
            guard offset.payload < end else { continue }
            let nal = Data(raw[offset.payload..<end])
            let type = raw[offset.payload] & 31
            if type == 7 { sps = nal }
            else if type == 8 { pps = nal }
            else {
                if type == 5 { key = true }
                if type == 1 || type == 5 { picture = true }
                var length = UInt32(nal.count).bigEndian
                withUnsafeBytes(of: &length) { encoded.append(contentsOf: $0) }
                encoded.append(nal)
            }
        }
        if key, let sps, let pps {
            try configure(sps: sps, pps: pps, lengthSize: 4)
        }
        guard picture else { return nil }
        return try sample(encoded, key: key)
    }

    private mutating func configure(sps: Data, pps: Data, lengthSize: Int) throws {
        var description: CMFormatDescription?
        let result = sps.withUnsafeBytes { first in
            pps.withUnsafeBytes { second in
                guard let first = first.bindMemory(to: UInt8.self).baseAddress,
                      let second = second.bindMemory(to: UInt8.self).baseAddress else { return OSStatus(-1) }
                let pointers = [first, second]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: Int32(lengthSize), formatDescriptionOut: &description
                )
            }
        }
        guard result == noErr, let description else { throw DeviceMediaFailure.invalidFrame }
        let size = CMVideoFormatDescriptionGetDimensions(description)
        guard (1...7_680).contains(size.width), (1...7_680).contains(size.height) else { throw DeviceMediaFailure.invalidFrame }
        format = description
        waitingForKey = true
    }

    mutating func sample(_ bytes: Data, key: Bool) throws -> DeviceVideoSample? {
        guard let format, !waitingForKey || key, !bytes.isEmpty else { return nil }
        var block: CMBlockBuffer?
        let allocated = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        guard allocated == noErr, let block else { throw DeviceMediaFailure.invalidFrame }
        let copied = bytes.withUnsafeBytes { source in
            guard let address = source.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferReplaceDataBytes(with: address, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard copied == noErr else { throw DeviceMediaFailure.invalidFrame }
        var buffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleSize = bytes.count
        let created = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &buffer
        )
        guard created == noErr, let buffer else { throw DeviceMediaFailure.invalidFrame }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
           let pointer = CFArrayGetValueAtIndex(attachments, 0) {
            let dictionary = unsafeBitCast(pointer, to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        waitingForKey = false
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        return .init(buffer: buffer, size: CGSize(width: Int(dimensions.width), height: Int(dimensions.height)), keyframe: key)
    }
}
