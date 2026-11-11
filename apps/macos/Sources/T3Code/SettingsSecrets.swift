import Foundation

struct SettingsSecretProvider: Equatable, Sendable {
    let id: String
    let label: String
}

struct SettingsSecretReference: Equatable, Sendable {
    let provider: String
    let reference: String

    init?(provider: String, reference: String) {
        let path = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_-]{0,63}/) != nil,
              !path.isEmpty, path.utf16.count <= 1_024, !path.contains("\r"), !path.contains("\n") else { return nil }
        self.provider = provider
        self.reference = path
    }

    init?(_ value: Wire) {
        guard let provider = value["provider"].string, let reference = value["reference"].string else { return nil }
        self.init(provider: provider, reference: reference)
    }

    var wire: Wire { .object(["provider": .string(provider), "reference": .string(reference)]) }
}

enum SettingsSecret {
    static let savedMarker = "••••••"
}
