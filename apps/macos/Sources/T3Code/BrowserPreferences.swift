import Foundation

struct BrowserProfile: Equatable, Sendable {
    enum Kind: String, Sendable { case persistent, incognito }

    static let standard = BrowserProfile(id: "default", name: "Default", kind: .persistent)
    static let incognito = BrowserProfile(id: "incognito", name: "Incognito", kind: .incognito)

    let id: String
    let name: String
    let kind: Kind

    var builtIn: Bool { id == Self.standard.id || id == Self.incognito.id }
    var wire: Wire { .object(["id": .string(id), "name": .string(name), "kind": .string(kind.rawValue)]) }

    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.utf16.count <= 64 && id == id.trimmingCharacters(in: .whitespacesAndNewlines) &&
            id.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

struct BrowserPreferences: Equatable, Sendable {
    static let storageKey = "browserPreferences"
    static let profileLimit = 24

    private(set) var customProfiles: [BrowserProfile] = []
    private(set) var defaultProfileID = BrowserProfile.standard.id
    private(set) var search = BrowserSearch()
    var display = BrowserDisplaySettings()
    var recording = BrowserRecordingPreferences()

    init(_ value: Wire = .null) {
        var seen = Set([BrowserProfile.standard.id, BrowserProfile.incognito.id])
        for item in value["profiles"].array {
            guard let id = item["id"].string, BrowserProfile.isValidID(id),
                  let name = item["name"].string.flatMap(Self.cleanedName), seen.insert(id).inserted else { continue }
            customProfiles.append(.init(id: id, name: name, kind: .persistent))
            if customProfiles.count == Self.profileLimit { break }
        }
        if let id = value["defaultProfileId"].string, profile(id)?.kind == .persistent {
            defaultProfileID = id
        }
        search = BrowserSearch(value["search"])
        display = BrowserDisplaySettings(value["display"])
        recording = BrowserRecordingPreferences(value)
    }

    var profiles: [BrowserProfile] { [.standard, .incognito] + customProfiles }
    var defaultProfile: BrowserProfile { profile(defaultProfileID) ?? .standard }

    var report: Payload {
        ["profiles": .array(customProfiles.map(\.wire)), "defaultProfileId": .string(defaultProfile.id),
         "recordingFrameRate": .int(recording.frameRate.rawValue)]
    }

    var storedValue: Wire {
        .object(report.merging([
            "search": search.wire, "display": display.wire,
            "recordingShowShortcuts": .bool(recording.showShortcuts),
            "recordingShowMousePresses": .bool(recording.showMousePresses),
        ]) { _, new in new })
    }

    func profile(_ id: String) -> BrowserProfile? { profiles.first { $0.id == id } }

    func nameProblem(_ input: String, for id: String?) -> String? {
        guard let name = Self.cleanedName(input) else { return "Enter a profile name up to 48 characters." }
        if profiles.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return "A profile already uses this name."
        }
        return nil
    }

    mutating func saveProfile(name input: String, editing id: String? = nil) throws {
        if let problem = nameProblem(input, for: id) { throw ClientError.message(problem) }
        guard let name = Self.cleanedName(input) else { throw ClientError.invalidResponse }
        if let id {
            guard let index = customProfiles.firstIndex(where: { $0.id == id }) else {
                throw ClientError.message("This profile is no longer available to edit.")
            }
            customProfiles[index] = .init(id: id, name: name, kind: .persistent)
        } else {
            guard customProfiles.count < Self.profileLimit else { throw ClientError.message("You can add up to 24 profiles.") }
            customProfiles.append(.init(id: "profile-\(UUID().uuidString.lowercased())", name: name, kind: .persistent))
        }
    }

    mutating func selectDefault(_ id: String) {
        if profile(id)?.kind == .persistent { defaultProfileID = id }
    }

    mutating func removeProfile(_ id: String) {
        customProfiles.removeAll { $0.id == id }
        if defaultProfileID == id { defaultProfileID = BrowserProfile.standard.id }
    }

    mutating func setSearchEngine(_ engine: BrowserSearch.Engine) {
        search.engine = engine
    }

    mutating func setCustomSearch(_ value: String) throws {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty || BrowserSearch.validTemplate(text) else {
            throw ClientError.message("Enter an HTTP or HTTPS search URL with %s for the search term.")
        }
        search.customTemplate = text
    }

    private static func cleanedName(_ input: String) -> String? {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf16.count <= 48,
              name.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return name
    }
}

struct BrowserSearch: Equatable, Sendable {
    enum Engine: String, CaseIterable, Sendable {
        case duckduckgo, google, bing, brave, kagi, ecosia, custom

        var title: String {
            switch self {
            case .duckduckgo: "DuckDuckGo"
            case .google: "Google"
            case .bing: "Bing"
            case .brave: "Brave Search"
            case .kagi: "Kagi"
            case .ecosia: "Ecosia"
            case .custom: "Custom"
            }
        }

        var template: String {
            switch self {
            case .duckduckgo, .custom: "https://duckduckgo.com/?q=%s"
            case .google: "https://www.google.com/search?q=%s"
            case .bing: "https://www.bing.com/search?q=%s"
            case .brave: "https://search.brave.com/search?q=%s"
            case .kagi: "https://kagi.com/search?q=%s"
            case .ecosia: "https://www.ecosia.org/search?q=%s"
            }
        }
    }

    var engine: Engine
    var customTemplate: String

    init(_ value: Wire = .null) {
        engine = value["engine"].string.flatMap(Engine.init(rawValue:)) ?? .duckduckgo
        let template = value["customTemplate"].string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        customTemplate = Self.validTemplate(template) ? template : ""
    }

    var wire: Wire { .object(["engine": .string(engine.rawValue), "customTemplate": .string(customTemplate)]) }

    func components(for query: String) -> URLComponents? {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        let template = engine == .custom && Self.validTemplate(customTemplate) ? customTemplate : engine.template
        return URLComponents(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    static func validTemplate(_ template: String) -> Bool {
        guard template.utf16.count <= 2_048, template.contains("%s"),
              let first = URLComponents(string: template.replacingOccurrences(of: "%s", with: "one")),
              let other = URLComponents(string: template.replacingOccurrences(of: "%s", with: "two")),
              ["http", "https"].contains(first.scheme?.lowercased() ?? ""),
              let host = first.host, !host.isEmpty, first.url != nil, other.url != nil else { return false }
        return first.scheme == other.scheme && first.host == other.host && first.port == other.port &&
            first.user == other.user && first.password == other.password
    }
}
