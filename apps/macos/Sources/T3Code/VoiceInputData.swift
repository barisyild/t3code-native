import Foundation

struct VoiceTarget: Equatable, Sendable {
    let connection: UUID
    let environmentID: String
    let serverID: String
}

struct VoiceInputPreferences: Codable, Equatable, Sendable {
    var grant: UUID?
    var cloud: VoiceCloudDestination?
    var cleanupGrant: UUID?
    var cleanupPrompt: String?
    var cleanupUsesCustomInstructions: Bool?
    var correctionCue: String?
    var language = "auto"
    var translate = false
    var removeFillers = true
    var filterSilence = true

    static let storageKey = "voiceInputPreferences"

    func options(for status: VoiceStatus?, vocabulary: [Wire], cleanup: Bool = false) -> Wire {
        let effectiveLanguage = status?.language(for: language) ?? (VoiceCloudDestination.languages.contains(language) ? language : "auto")
        var options: Payload = [
            "speechLanguage": .string(effectiveLanguage),
            "speechTranslateToEnglish": .bool(translate && status?.canTranslate == true),
            "speechCustomWords": .array(vocabulary), "speechRemoveFillerWords": .bool(removeFillers),
            "speechSilenceFiltering": .bool(filterSilence),
        ]
        if cleanup, let cue = cleanedCorrectionCue { options["speechCorrectionWord"] = .string(cue) }
        return .object(options)
    }

    var cleanedCorrectionCue: String? {
        correctionCue.flatMap { $0.isEmpty || $0.utf16.count > 50 ? nil : $0 }
    }

    var usesCustomCleanupInstructions: Bool { cleanupUsesCustomInstructions ?? (cleanupPrompt != nil) }

    func cleanupOptions(vocabulary: [Wire]) -> Wire {
        var options: Payload = [
            "speechCustomWords": .array(vocabulary),
            "speechPostProcessingPrompt": .object([
                "mode": .string(usesCustomCleanupInstructions ? "custom" : "default"),
                "customInstructions": .string(usesCustomCleanupInstructions ? cleanupPrompt ?? "" : ""),
            ]),
        ]
        if let cue = cleanedCorrectionCue { options["speechCorrectionWord"] = .string(cue) }
        return .object(options)
    }
}

struct VoiceStatus: Equatable, Sendable {
    let supported: Bool
    let reason: String?
    let state: String?
    let streams: Bool
    let canTranslate: Bool
    let detectsLanguage: Bool
    let languages: [String]

    init?(_ value: Wire) {
        guard let supported = value["supported"].bool else { return nil }
        self.supported = supported
        reason = value["reason"].string
        state = value["state"].string
        streams = value["supportsStreaming"].bool == true || value["supportsBufferedStreaming"].bool == true
        canTranslate = value["supportsTranslation"].bool == true
        detectsLanguage = value["supportsLanguageDetection"].bool == true
        languages = value["languages"].array.compactMap(\.string)
    }

    var languageChoices: [String] {
        var seen = Set<String>()
        let choices = (detectsLanguage ? ["auto"] : []) + languages.filter { $0 != "auto" }
        return (choices.isEmpty ? ["en"] : choices).filter { seen.insert($0).inserted }
    }

    func language(for preferred: String) -> String {
        if languageChoices.contains(preferred) { return preferred }
        if detectsLanguage { return "auto" }
        let system = Locale.preferredLanguages.compactMap { $0.split(separator: "-").first.map(String.init) }
        return system.first { languageChoices.contains($0) } ?? languageChoices.first ?? "en"
    }
}

struct VoiceModel: Equatable, Sendable {
    enum State: String { case downloadable, downloading, verifying, installed }

    let id: String
    let name: String
    let bytes: Int64
    let state: State
    let active: Bool
    let downloaded: Double?

    init?(_ value: Wire) {
        guard let id = value["id"].string, let name = value["name"].string,
              let state = value["state"].string.flatMap(State.init(rawValue:)),
              let bytes = value["size"].double, bytes >= 0, bytes < Double(Int64.max) else { return nil }
        self.id = id
        self.name = name
        self.state = state
        self.bytes = Int64(bytes)
        active = value["active"].bool == true
        downloaded = value["downloaded"].double
    }

    var statusLabel: String {
        switch state {
        case .installed: active ? "Selected" : "Installed"
        case .downloadable: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        case .downloading:
            if let downloaded, downloaded.isFinite, bytes > 0 {
                "Downloading \(Int(min(100, max(0, downloaded / Double(bytes) * 100))))%"
            } else { "Downloading…" }
        case .verifying: "Verifying…"
        }
    }
}

enum VoicePCM {
    static let sampleRate = 16_000
    static let bytesPerSample = MemoryLayout<Float32>.size
    static let chunkLimit = sampleRate * bytesPerSample
    static let recordingLimit = chunkLimit * 5 * 60
    static let optionsLimit = 128_000

    static func request(_ audio: Data, options: Wire) throws -> Data {
        guard !audio.isEmpty, audio.count <= recordingLimit, audio.count.isMultiple(of: bytesPerSample) else {
            throw ClientError.message("No usable microphone audio was recorded.")
        }
        let metadata = try JSONEncoder().encode(options)
        guard metadata.count <= optionsLimit else { throw ClientError.invalidResponse }
        var length = UInt32(metadata.count).littleEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.reserveCapacity(4 + metadata.count + audio.count)
        data.append(metadata)
        data.append(audio)
        return data
    }
}

struct VoiceDraftAnchor: Equatable {
    let revision: Int
    let range: NSRange

    func cleanupContext(_ draft: String) -> Wire? {
        let units = draft.utf16
        guard range.location >= 0, range.location <= units.count, range.length >= 0,
              range.length <= units.count - range.location else { return nil }
        let before = units.prefix(range.location).suffix(1_024)
        let selected = units.dropFirst(range.location).prefix(min(1_024, range.length))
        let after = units.dropFirst(range.location + range.length).prefix(1_024)
        let text = String(decoding: Array(before) + Array(selected) + Array(after), as: UTF16.self)
        return .object(["text": .string(text), "selection": .object([
            "start": .int(before.count), "end": .int(before.count + selected.count),
        ])])
    }

    func insertion(_ transcript: String, draft: String, revision: Int, language: String) throws -> String {
        guard self.revision == revision, let selection = Range(range, in: draft) else {
            throw ClientError.message("The draft changed during dictation. Record again to insert text.")
        }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClientError.message("No speech was detected.") }
        let base = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? "auto"
        guard range.length == 0, !["ja", "zh", "yue", "th", "lo", "km", "my"].contains(base) else { return text }
        let left = draft[..<selection.lowerBound].last
        let right = draft[selection.upperBound...].first
        let endsWord = left.map { $0.isLetter || $0.isNumber || ".!?,:;)]}'\"".contains($0) } == true
        let startsWord = right.map { $0.isLetter || $0.isNumber || "([{'\"".contains($0) } == true
        let leadingLatin = base != "auto" || text.range(of: #"^[\p{Latin}\p{N}]"#, options: .regularExpression) != nil
        let trailingLatin = base != "auto" || text.range(of: #"[\p{Latin}\p{N}]$"#, options: .regularExpression) != nil
        let prefix = leadingLatin && endsWord && (right == nil || right?.isWhitespace == true) ? " " : ""
        let suffix = trailingLatin && startsWord && (left == nil || left?.isWhitespace == true) ? " " : ""
        return prefix + text + suffix
    }
}
