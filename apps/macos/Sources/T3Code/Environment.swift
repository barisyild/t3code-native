import Foundation
import Security

struct PairingTarget: Sendable {
    let origin: URL
    let credential: String
    let label: String?

    init(address: String, code: String) throws {
        var address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        var credential = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if let appLink = URLComponents(string: address),
           ["t3code", "t3code-dev"].contains(appLink.scheme), appLink.host == "pair",
           let nested = appLink.queryItems?.first(where: { $0.name == "pairingUrl" })?.value {
            address = nested
        }
        var components = try Self.components(address)
        let search = components.queryItems ?? []
        var fragment = URLComponents()
        fragment.percentEncodedQuery = components.percentEncodedFragment
        let token = (fragment.queryItems ?? []).first { $0.name == "token" }?.value
            ?? search.first { $0.name == "token" }?.value
        if let token, !token.isEmpty { credential = token }
        if let host = search.first(where: { $0.name == "host" })?.value, token != nil {
            components = try Self.components(host)
        }
        guard !credential.isEmpty else { throw ClientError.message("Enter a pairing code or paste a complete pairing link.") }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let origin = components.url else { throw ClientError.message("Enter a valid server address.") }
        self.origin = origin
        self.credential = credential
        label = search.first { $0.name == "label" }?.value
    }

    private static func components(_ address: String) throws -> URLComponents {
        let value = address.contains("://") ? address : "https://\(address)"
        guard var components = URLComponents(string: value), let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else {
            throw ClientError.message("Enter a valid server address.")
        }
        switch components.scheme?.lowercased() {
        case "http", "ws": components.scheme = "http"
        case "https", "wss": components.scheme = "https"
        default: throw ClientError.message("Use an HTTP or HTTPS server address.")
        }
        components.host = host.lowercased()
        if (components.scheme == "https" && components.port == 443) ||
            (components.scheme == "http" && components.port == 80) { components.port = nil }
        return components
    }
}

struct SavedEnvironment: Codable, Sendable, Equatable {
    let origin: URL
    let name: String
    var relay: RelayRoute? = nil
    var serverID: String? = nil

    var id: String { relay?.storageID ?? origin.absoluteString }
    var canonicalID: String? { relay?.environmentID ?? serverID }

    var isLocal: Bool {
        relay == nil && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(origin.host() ?? "")
    }
}

enum EnvironmentKeychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.t3tools.t3code.appkit.environment",
         kSecAttrAccount as String: account]
    }

    static func load(_ origin: URL) throws -> String? { try load(account: origin.absoluteString) }

    static func load(account: String) throws -> String? {
        var item = query(account)
        item[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw ClientError.message("The saved session could not be read from Keychain (\(status)).")
        }
        return token
    }

    static func save(_ token: String, for origin: URL) throws { try save(token, account: origin.absoluteString) }

    static func save(_ token: String, account: String, onlyIfAbsent: Bool = false) throws {
        let item = query(account)
        let data = [kSecValueData as String: Data(token.utf8)]
        var status = onlyIfAbsent ? errSecItemNotFound : SecItemUpdate(item as CFDictionary, data as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(item.merging(data) { _, new in new } as CFDictionary, nil)
        }
        if onlyIfAbsent && status == errSecDuplicateItem { return }
        guard status == errSecSuccess else {
            throw ClientError.message("The session could not be saved to Keychain (\(status)).")
        }
    }

    static func remove(_ origin: URL) throws {
        let status = SecItemDelete(query(origin.absoluteString) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ClientError.message("The saved session could not be removed from Keychain (\(status)).")
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

typealias EnvironmentHTTP = @Sendable (URLRequest) async throws -> Wire

struct EnvironmentAPI: Sendable {
    static let orchestrationProtocol = "2"
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()
    private static let browserSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 180
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    let origin: URL
    var token: String?
    let relay: RelayEnvironmentAccess?
    private let transport: EnvironmentHTTP

    init(origin: URL, token: String? = nil, relay: RelayEnvironmentAccess? = nil,
         transport: @escaping EnvironmentHTTP = EnvironmentAPI.send) {
        self.origin = origin
        self.token = token
        self.relay = relay
        self.transport = transport
    }

    func exchange(_ credential: String) async throws -> String {
        let result = try await exchangeBootstrap(credential)
        guard result["token_type"].string == "Bearer" else { throw ClientError.invalidResponse }
        return try result.requireString("access_token")
    }

    func exchangeBootstrap(_ credential: String, proof: String? = nil) async throws -> Wire {
        let fields = [
            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
            "subject_token": credential,
            "subject_token_type": "urn:t3:params:oauth:token-type:environment-bootstrap",
            "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
            "client_label": "T3 Code for macOS",
            "client_device_type": "desktop",
            "client_os": "macOS",
        ]
        return try await http("/oauth/token", method: "POST", body: Self.form(fields),
                              contentType: "application/x-www-form-urlencoded",
                              headers: proof.map { ["DPoP": $0] } ?? [:])
    }

    static func form(_ fields: [String: String]) -> Data {
        var form = URLComponents()
        form.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        let encoded = (form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        return Data(encoded.utf8)
    }

    func connect() async throws -> RPCSocket {
        let socket = RPCSocket(session: Self.session, url: try await socketURL())
        await socket.start()
        return socket
    }

    func socketURL() async throws -> URL {
        let ticket: Wire
        do { ticket = try await http("/api/auth/websocket-ticket/rpc", method: "POST") }
        catch ClientError.http(404, _) { ticket = try await http("/api/auth/websocket-ticket", method: "POST") }
        let ticketValue = try ticket.requireString("ticket")
        var components: URLComponents
        var parameters = [
            URLQueryItem(name: "wsTicket", value: ticketValue),
            URLQueryItem(name: "orchestrationProtocol", value: Self.orchestrationProtocol),
            URLQueryItem(name: "clientCapabilities", value: "settingsSecretReferences"),
            URLQueryItem(name: "clientSurface", value: "desktop"),
            URLQueryItem(name: "clientDeviceType", value: "desktop"),
            URLQueryItem(name: "clientOs", value: "macOS"),
        ]
        if let relay {
            guard var upgrade = URLComponents(url: relay.endpoint.socket, resolvingAgainstBaseURL: false) else {
                throw ClientError.invalidResponse
            }
            components = upgrade
            upgrade.scheme = "https"
            guard let proofURL = upgrade.url else { throw ClientError.invalidResponse }
            let proof = try await relay.client.proof(method: "GET", url: proofURL, token: ticketValue)
            parameters.append(URLQueryItem(name: "dpop", value: proof))
            parameters.append(URLQueryItem(name: "connectionMethod", value: "relay"))
        } else {
            components = try endpoint("/ws")
            components.scheme = components.scheme == "https" ? "wss" : "ws"
        }
        components.queryItems = parameters
        guard let url = components.url else { throw ClientError.invalidResponse }
        return url
    }

    func http(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil,
              contentType: String? = nil, timeout: TimeInterval? = nil,
              headers: [String: String] = [:]) async throws -> Wire {
        var components = try endpoint(path)
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ClientError.invalidResponse }
        var request = URLRequest(url: url)
        if let timeout { request.timeoutInterval = timeout }
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if path.hasPrefix("/api/orchestration/") {
            request.setValue(Self.orchestrationProtocol, forHTTPHeaderField: "x-t3-orchestration-protocol")
        }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        guard let relay else { return try await transport(request) }
        let authorization = try await relay.authorize(method: method, url: url)
        do {
            return try await transport(authorization.apply(to: request))
        } catch ClientError.http(401, _) {
            await relay.client.invalidate(authorization.token, for: relay.route)
            try Task.checkCancellation()
            let fresh = try await relay.authorize(method: method, url: url)
            return try await transport(fresh.apply(to: request))
        }
    }

    static func send(_ request: URLRequest) async throws -> Wire {
        let (data, response) = try await Self.session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        let decoded = try? JSONDecoder().decode(Wire.self, from: data)
        guard (200..<300).contains(response.statusCode) else {
            throw ClientError.http(response.statusCode, decoded?["error_description"].string ?? decoded?.serverErrorMessage)
        }
        if response.statusCode == 204 && data.isEmpty { return .null }
        guard let decoded else { throw ClientError.invalidResponse }
        return decoded
    }

    func upload(_ file: PickedAttachment, to relativePath: String) async throws {
        guard relativePath.hasPrefix("/api/attachments/upload/"),
              let url = URL(string: relativePath, relativeTo: origin)?.absoluteURL,
              url.host() == origin.host(), url.scheme == origin.scheme, url.port == origin.port else {
            throw ClientError.invalidResponse
        }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue(file.mimeType, forHTTPHeaderField: "Content-Type")
        let (_, response) = try await Self.session.upload(for: request, fromFile: file.url)
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw ClientError.http(response.statusCode, "Couldn’t upload \(file.name) (HTTP \(response.statusCode)).")
        }
    }

    func assetRequest(_ relativeURL: String) throws -> URLRequest {
        guard relativeURL.hasPrefix("/api/assets/"),
              let url = URL(string: relativeURL, relativeTo: origin)?.absoluteURL,
              url.scheme == origin.scheme, url.host() == origin.host(), url.port == origin.port,
              url.path.hasPrefix("/api/assets/"),
              !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else {
            throw ClientError.invalidResponse
        }
        return URLRequest(url: url, timeoutInterval: 120)
    }

    func downloadAsset(_ relativeURL: String, maximumBytes: Int? = nil) async throws -> URL {
        let request = try assetRequest(relativeURL)
        let (file, response) = try await Self.browserSession.download(for: request)
        do {
            guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else {
                throw ClientError.http(response.statusCode, "Couldn’t download this file (HTTP \(response.statusCode)).")
            }
            if let maximumBytes {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= maximumBytes else {
                    throw ClientError.message("This attachment exceeds its download limit or is empty.")
                }
            }
            try Task.checkCancellation()
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    func browserStream(threadId: String, tabId: String, interactive: Bool) async throws -> BrowserStream {
        let url = try await browserURL("ws", threadId: threadId, tabId: tabId, query: [
            URLQueryItem(name: "maxWidth", value: "1920"),
            URLQueryItem(name: "maxHeight", value: "1200"),
            URLQueryItem(name: "interactive", value: interactive ? "true" : "false"),
        ], webSocket: true)
        try Task.checkCancellation()
        return BrowserStream(socket: Self.browserSession.webSocketTask(with: url))
    }

    @MainActor
    func voiceStream() async throws -> VoiceSpeechStream {
        let ticket = try await http("/api/auth/websocket-ticket/media", method: "POST")
        var address = try endpoint("/ws/voice")
        address.scheme = address.scheme == "https" ? "wss" : "ws"
        address.queryItems = [URLQueryItem(name: "wsTicket", value: try ticket.requireString("ticket"))]
        guard let url = address.url else { throw ClientError.invalidResponse }
        try Task.checkCancellation()
        return VoiceSpeechStream(socket: Self.browserSession.webSocketTask(with: url))
    }

    func downloadBrowserFile(threadId: String, tabId: String, downloadId: String) async throws -> URL {
        let url = try await browserURL("download", threadId: threadId, tabId: tabId,
                                       query: [URLQueryItem(name: "id", value: downloadId)])
        let (file, response) = try await Self.browserSession.download(from: url)
        do { try Self.requireBrowserSuccess(response) }
        catch { try? FileManager.default.removeItem(at: file); throw error }
        return file
    }

    func uploadBrowserFiles(_ files: [URL], threadId: String, tabId: String, chooserId: String) async throws {
        let upload = try BrowserMultipart(files: files)
        defer { upload.remove() }
        let url = try await browserURL("upload", threadId: threadId, tabId: tabId,
                                       query: [URLQueryItem(name: "chooser", value: chooserId)])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(upload.boundary)", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await Self.browserSession.upload(for: request, fromFile: upload.file)
        try Self.requireBrowserSuccess(response)
    }

    private func browserURL(_ route: String, threadId: String, tabId: String, query: [URLQueryItem],
                            webSocket: Bool = false) async throws -> URL {
        let ticket = try await http("/api/auth/websocket-ticket/media", method: "POST")
        var components = try endpoint("/api/preview-stream/\(route)")
        if webSocket { components.scheme = components.scheme == "https" ? "wss" : "ws" }
        components.queryItems = [
            URLQueryItem(name: "threadId", value: threadId), URLQueryItem(name: "tabId", value: tabId),
            URLQueryItem(name: "wsTicket", value: try ticket.requireString("ticket")),
        ] + query
        guard let url = components.url else { throw ClientError.invalidResponse }
        return url
    }

    private static func requireBrowserSuccess(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw ClientError.http(response.statusCode, "The browser host refused the file transfer (HTTP \(response.statusCode)).")
        }
    }

    private func endpoint(_ path: String) throws -> URLComponents {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            throw ClientError.invalidResponse
        }
        components.path = path
        return components
    }
}
