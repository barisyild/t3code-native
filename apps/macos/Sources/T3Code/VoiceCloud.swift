import Foundation

enum VoiceCloudProvider: String, CaseIterable, Codable, Sendable {
    case openai, xai, openrouter

    var name: String {
        switch self {
        case .openai: "OpenAI"
        case .xai: "xAI"
        case .openrouter: "OpenRouter"
        }
    }

    var title: String { self == .xai ? "Grok Voice Transcribe" : name }

    func disclosure(environment: String) -> String {
        if self == .openrouter {
            return "When you finish recording, \(environment) sends the audio to OpenRouter. T3 requests zero data retention from its routes."
        }
        return "When you finish recording, \(environment) sends the audio and vocabulary hints, including the project name, to \(name)."
    }

    func error(_ reason: String?) -> String {
        switch reason {
        case "missing-key": "Add a \(name) API key in Voice Settings."
        case "unreadable-key": "Unlock the vault on the environment or update the \(name) key in Voice Settings."
        case "key-changed": "The \(name) key changed during dictation. Record again to retry."
        case "rejected-key": "\(name) rejected the API key. Check its permissions in Voice Settings."
        case "rate-limit": "\(name) reached a usage limit."
        case "model-unavailable": "Choose an available \(name) transcription model in Voice Settings."
        default: "\(name) couldn’t transcribe the recording."
        }
    }

    static func apiKey(_ value: String) -> Wire? {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 4_096, key.utf8.allSatisfy({ (33...126).contains($0) }),
              key.range(of: #"^[a-z][a-z\d+.-]*://"#, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        return .string(key)
    }
}

struct VoiceCloudDestination: Codable, Equatable, Sendable {
    let provider: VoiceCloudProvider
    let model: String?

    init?(provider: VoiceCloudProvider, model: String? = nil) {
        if provider == .openrouter {
            guard let model, VoiceCloudModel.validID(model) else { return nil }
        } else if model != nil { return nil }
        self.provider = provider
        self.model = model
    }

    var isValid: Bool { Self(provider: provider, model: model) != nil }
    var title: String { model.map { "\(provider.title) · \($0)" } ?? provider.title }

    static let languages = "auto ar bg ca cs da de el en es fa fi fr hi hr hu id it ja ko mk ms nl pl pt ro ru sk sv th tr uk ur vi zh"
        .split(separator: " ").map(String.init)
}

struct VoiceCloudModel: Equatable, Sendable {
    let id: String
    let name: String

    init?(_ value: Wire) {
        guard let id = value["id"].string, Self.validID(id), let name = value["name"].string else { return nil }
        self.id = id
        self.name = name
    }

    static func validID(_ id: String) -> Bool {
        id.utf8.count <= 160 && !id.lowercased().hasPrefix("openrouter/") &&
            id.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9.-]*\/[A-Za-z0-9][A-Za-z0-9._-]*/) != nil
    }
}

extension EnvironmentAPI {
    func cloudVoiceKeys() async throws -> Wire { try await http("/api/voice/cloud/keys", timeout: 30) }

    func cloudVoiceModels() async throws -> [VoiceCloudModel] {
        let reply = try await http("/api/voice/cloud/openrouter/models", timeout: 30)
        guard case .array(let rows) = reply["models"] else { throw ClientError.invalidResponse }
        return rows.compactMap(VoiceCloudModel.init)
    }

    func setCloudVoiceKey(_ key: Wire, for provider: VoiceCloudProvider) async throws {
        let body = try JSONEncoder().encode(Wire.object(["key": key]))
        _ = try await http("/api/voice/cloud/\(provider.rawValue)/key", method: "POST", body: body,
                           contentType: "application/json", timeout: 30)
    }

    func transcribeVoice(_ audio: Data, options: Wire, cloud: VoiceCloudDestination?) async throws -> String {
        let body = try VoicePCM.request(audio, options: options)
        let path = cloud.map { "/api/voice/cloud/\($0.provider.rawValue)/transcribe" } ?? "/api/voice/transcribe"
        let query = cloud?.model.map { [URLQueryItem(name: "model", value: $0)] } ?? []
        let reply = try await http(path, method: "POST", query: query, body: body, contentType: "application/octet-stream", timeout: 130)
        return try reply.requireString("text")
    }
}
