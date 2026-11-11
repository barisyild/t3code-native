import Foundation

struct McpAppPage: Equatable, Sendable {
    static let maximumHTMLBytes = 5 * 1024 * 1024
    static let maximumHeight: CGFloat = 2_000
    private static let domainPattern = #"(?i)\A(?:https?|wss?)://(?:\*\.)?[a-z0-9-]+(?:\.[a-z0-9-]+)*(?::\d{1,5})?\z"#

    let attachmentID: String
    let server: String
    let tool: String
    let resourceURI: String
    let threadID: String
    let itemID: String
    let revision: String?
    let domains: [String: [String]]
    let permissions: Set<String>
    let prefersBorder: Bool

    init?(_ entry: TimelineEntry) {
        guard entry.type == "dynamic_tool",
              let app = ConversationToolOutput.successful(entry.value["output"])?["t3McpApp"],
              let id = Self.name(app["attachmentId"]), let server = Self.name(app["server"]), let tool = Self.name(app["tool"]),
              let uri = app["resourceUri"].string, uri.hasPrefix("ui://"), uri.utf16.count <= 4_096,
              let name = entry.value["toolName"].string, name == "\(server).\(tool)" || name == Self.claudeName(server: server, tool: tool)
        else { return nil }
        attachmentID = id
        self.server = server
        self.tool = tool
        resourceURI = uri
        threadID = entry.sourceThreadID
        itemID = entry.id
        revision = entry.value["updatedAt"].string
        var domains: [String: [String]] = [:]
        for key in ["resourceDomains", "connectDomains", "frameDomains", "baseUriDomains"] {
            let values = app["csp"][key].array.lazy.compactMap(\.string).filter {
                $0.utf16.count <= 256 && $0.range(of: Self.domainPattern, options: .regularExpression) != nil
            }.prefix(32)
            if !values.isEmpty { domains[key] = Array(values) }
        }
        self.domains = domains
        permissions = Set(["camera", "microphone", "geolocation", "clipboardWrite"].filter { app["permissions"][$0].object != nil })
        prefersBorder = app["prefersBorder"].bool == true
    }

    var title: String { "\(server) app" }
    var fileName: String {
        let clean = String(tool.replacingOccurrences(of: #"[^a-zA-Z0-9_.-]+"#, with: "-", options: .regularExpression).prefix(80))
        return (clean.isEmpty ? "app" : clean) + ".html"
    }
    var resource: Wire {
        .object(["_tag": .string("attachment"), "attachmentId": .string(attachmentID), "fileName": .string(fileName),
                 "mimeType": .string("text/html"), "disposition": .string("inline"), "renderIntent": .string("mcp-app")])
    }
    var metadata: Wire {
        var value: Payload = ["attachmentId": .string(attachmentID), "server": .string(server), "tool": .string(tool),
                              "resourceUri": .string(resourceURI)]
        if !domains.isEmpty { value["csp"] = .object(domains.mapValues { .array($0.map(Wire.string)) }) }
        if !permissions.isEmpty {
            value["permissions"] = .object(Dictionary(uniqueKeysWithValues: permissions.map { ($0, Wire.object([:])) }))
        }
        return .object(value)
    }

    var allow: String {
        permissions.sorted().map { $0 == "clipboardWrite" ? "clipboard-write" : $0 }.joined(separator: "; ")
    }

    func allowsFrame(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host()?.lowercased(),
              url.user() == nil, url.password() == nil else { return false }
        return domains["frameDomains", default: []].contains { source in
            guard let domain = URLComponents(string: source), domain.scheme?.lowercased() == scheme,
                  let declared = domain.host?.lowercased(), (url.port ?? (scheme == "https" ? 443 : 80)) == (domain.port ?? (scheme == "https" ? 443 : 80))
            else { return false }
            return declared.hasPrefix("*.") ? host.hasSuffix(String(declared.dropFirst())) && host != String(declared.dropFirst(2)) : host == declared
        }
    }

    private static func name(_ value: Wire) -> String? {
        guard let name = value.string, name.utf16.count <= 256,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return name
    }

    private static func claudeName(server: String, tool: String) -> String {
        func part(_ value: String) -> String {
            value.replacingOccurrences(of: #"[^a-zA-Z0-9_-]"#, with: "_", options: .regularExpression)
        }
        let serverName = server.hasPrefix("claude.ai ") ?
            part(server).replacingOccurrences(of: #"_+"#, with: "_", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "_")) : part(server)
        return "mcp__\(serverName)__\(part(tool))"
    }
}

enum ConversationPage: Equatable, Sendable {
    case html(HtmlReplyReference)
    case mcp(McpAppPage)

    var app: McpAppPage? { if case .mcp(let app) = self { return app }; return nil }
    var title: String { switch self { case .html(let page): page.title; case .mcp(let app): app.title } }
    var fileName: String { switch self { case .html(let page): page.fileName; case .mcp(let app): app.fileName } }
    var resource: Wire { switch self { case .html(let page): page.resource; case .mcp(let app): app.resource } }
    var cacheKey: String {
        switch self {
        case .html(let page): "html/" + page.attachmentID
        case .mcp(let app): "mcp/" + app.attachmentID
        }
    }
    var maximumBytes: Int { app == nil ? 25 * 1024 * 1024 : McpAppPage.maximumHTMLBytes }

    func frameHeight(width: CGFloat, zoom: CGFloat, liveHeight: CGFloat?) -> CGFloat {
        switch self {
        case .html(let page): page.frameHeight(width: width, zoom: zoom, liveHeight: liveHeight)
        case .mcp: min(McpAppPage.maximumHeight, max(80, (liveHeight ?? 320).rounded()))
        }
    }
}
