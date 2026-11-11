import Foundation

struct BrowserTab: Equatable, Sendable {
    let id: String
    let profileID: String?
    let isolatedAgent: Bool
    let display: BrowserDisplaySettings
    var title: String
    var url: String?
    var status: String
    var failure: String?
    var canGoBack: Bool
    var canGoForward: Bool
    let reveal: Bool
    let revealRequest: String?

    var displayName: String {
        if !title.isEmpty { return title }
        return url.flatMap { URL(string: $0)?.host() } ?? url ?? "New tab"
    }

    init?(_ snapshot: Wire) {
        guard snapshot["runtime"].string == "server", let id = snapshot["tabId"].string else { return nil }
        let navigation = snapshot["navStatus"]
        self.id = id
        profileID = snapshot["profileId"].string.flatMap { BrowserProfile.isValidID($0) ? $0 : nil }
        isolatedAgent = profileID == nil && snapshot["automationOwner"].string != nil
        display = BrowserDisplaySettings(snapshot)
        title = navigation["title"].string ?? ""
        url = navigation["url"].string
        status = navigation["_tag"].string ?? "Idle"
        failure = navigation["description"].string
        canGoBack = snapshot["canGoBack"].bool == true
        canGoForward = snapshot["canGoForward"].bool == true
        reveal = snapshot["reveal"].bool == true
        revealRequest = snapshot["revealRequest"]["id"].string
    }
}

struct BrowserTabs {
    enum Event: Equatable {
        case ignored
        case refresh
        case changed(reveal: String?)
    }

    private(set) var tabs: [BrowserTab] = []
    private(set) var loaded = false
    private var epoch: String?
    private var revision = -1

    /// An event can arrive while the initial list is in flight. An older list must never close or resurrect a tab.
    mutating func reconcile(_ list: Wire) throws -> Bool {
        let nextEpoch = try list.requireString("serverEpoch")
        guard let nextRevision = list["revision"].int else { throw ClientError.invalidResponse }
        guard epoch != nextEpoch || nextRevision >= revision else { return false }
        epoch = nextEpoch
        revision = nextRevision
        tabs = list["sessions"].array.compactMap(BrowserTab.init)
        loaded = true
        return true
    }

    mutating func apply(_ event: Wire, threadId: String) -> Event {
        guard event["threadId"].string == threadId, let id = event["tabId"].string,
              let nextEpoch = event["serverEpoch"].string, let nextRevision = event["revision"].int else { return .ignored }
        if let epoch, epoch != nextEpoch { return .refresh }
        guard nextRevision > revision else { return .ignored }
        epoch = nextEpoch
        revision = nextRevision

        switch event["type"].string {
        case "opened", "navigated", "resized":
            guard let updated = BrowserTab(event["snapshot"]), updated.id == id else { return .ignored }
            let index = tabs.firstIndex { $0.id == id }
            let old = index.map { tabs[$0] }
            if let index { tabs[index] = updated }
            else { tabs.append(updated) }
            let shouldReveal = loaded && updated.reveal &&
                (old == nil || (updated.revealRequest != nil && updated.revealRequest != old?.revealRequest))
            return .changed(reveal: shouldReveal ? id : nil)
        case "closed":
            guard let index = tabs.firstIndex(where: { $0.id == id }) else { return .ignored }
            tabs.remove(at: index)
            return .changed(reveal: nil)
        case "failed":
            guard let index = tabs.firstIndex(where: { $0.id == id }) else { return .ignored }
            tabs[index].status = "LoadFailed"
            tabs[index].url = event["url"].string ?? tabs[index].url
            tabs[index].title = event["title"].string ?? tabs[index].title
            tabs[index].failure = event["description"].string
            return .changed(reveal: nil)
        default: return .ignored
        }
    }
}

enum BrowserAddress {
    static func resolve(_ input: String, allowsSearch: Bool = true, search: BrowserSearch = BrowserSearch()) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ClientError.message("Enter a web address or search terms.") }
        let explicit = value.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*://", options: .regularExpression) != nil
        let authority = value.prefix { !"/?#".contains($0) }
        let loopback = authority.range(of: "^(localhost|127\\.0\\.0\\.1|0\\.0\\.0\\.0|\\[::1?\\])(:[0-9]+)?$",
                                       options: [.caseInsensitive, .regularExpression]) != nil
        let hostAndPort = authority.range(of: "^[a-zA-Z0-9.-]+:[0-9]+$", options: .regularExpression) != nil
        let scheme = value.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression)
        let forbidden = ["javascript:", "data:", "file:", "about:", "mailto:", "blob:"]
        if let scheme, forbidden.contains(value[scheme].lowercased()) || (!explicit && !hostAndPort && !loopback) {
            throw ClientError.message("Enter an HTTP or HTTPS address.")
        }

        let hasSpaces = value.contains(where: \.isWhitespace)
        let looksLikeAddress = explicit || (!hasSpaces && (!allowsSearch || loopback || hostAndPort || authority.contains(".") || authority.hasPrefix("[")))
        let components: URLComponents?
        if looksLikeAddress {
            components = URLComponents(string: explicit ? value : (loopback ? "http://" : "https://") + value)
        } else {
            guard allowsSearch else { throw ClientError.message("Enter an HTTP or HTTPS address.") }
            components = search.components(for: value)
        }
        guard let components, ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty, let url = components.url,
              url.absoluteString.utf16.count <= 2_048 else {
            throw ClientError.message("Enter a valid HTTP or HTTPS address up to 2,048 characters.")
        }
        return url.absoluteString
    }
}
