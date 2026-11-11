import Foundation
import Network

enum ProviderBrowserAddress {
    static func url(_ value: String) -> URL? {
        guard value.utf16.count <= 16_384, let components = URLComponents(string: value),
              ["https", "http"].contains(components.scheme?.lowercased()), let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        return components.url
    }
}

struct CodexAuthorizationRequest: Sendable {
    let page: URL
    let port: UInt16
    private let state: String

    init?(_ raw: String) {
        guard let page = ProviderBrowserAddress.url(raw), let parts = URLComponents(url: page, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "auth.openai.com", parts.port == nil || parts.port == 443,
              parts.percentEncodedPath == "/api/accounts/authorize", parts.fragment == nil else { return nil }
        func query(_ key: String) -> String? {
            let values = parts.queryItems?.filter { $0.name == key } ?? []
            return values.count == 1 ? values.first?.value : nil
        }
        guard let redirect = query("redirect_uri"), let loopback = redirect.wholeMatch(of: /http:\/\/127\.0\.0\.1:([1-9][0-9]{0,4})\/auth\/callback/),
              let port = UInt16(loopback.1), let state = query("state"), state.wholeMatch(of: /[A-Za-z0-9_-]{16,128}/) != nil,
              query("response_type") == "code", query("code_challenge_method") == "S256",
              query("code_challenge")?.wholeMatch(of: /[A-Za-z0-9_-]{43}/) != nil,
              query("client_id")?.wholeMatch(of: /(?:dynamic_agent_client|oaiapp_[A-Za-z0-9_-]+)/) != nil else { return nil }
        self.page = page
        self.port = port
        self.state = state
    }

    func callback(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.contains("://") ? trimmed : "http://" + trimmed
        let failure = ClientError.message("This redirect URL does not belong to the current sign-in.")
        guard value.utf16.count <= 16_384, let parts = URLComponents(string: value),
              parts.scheme == "http", parts.host == "127.0.0.1", parts.port == Int(port),
              parts.percentEncodedPath == "/auth/callback", parts.fragment == nil, parts.user == nil, parts.password == nil,
              let url = parts.url else { throw failure }
        let query = parts.queryItems ?? []
        let states = query.filter { $0.name == "state" }
        let codes = query.filter { $0.name == "code" }
        let errors = query.filter { $0.name == "error" }
        let clients = query.filter { $0.name == "client_id" }
        guard states.count == 1, states.first?.value == state,
              clients.isEmpty || (clients.count == 1 && clients.first?.value?.wholeMatch(of: /oaiapp_[A-Za-z0-9_-]+/) != nil),
              (codes.count == 1 && codes.first?.value?.isEmpty == false && errors.isEmpty) ||
                (errors.count == 1 && errors.first?.value?.isEmpty == false && codes.isEmpty) else { throw failure }
        return url.absoluteString
    }

    func callback(request header: Data) throws -> String {
        guard let request = String(data: header, encoding: .utf8), let line = request.components(separatedBy: "\r\n").first else {
            throw ClientError.invalidResponse
        }
        let fields = line.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0] == "GET", fields[1].hasPrefix("/auth/callback?"),
              fields[2] == "HTTP/1.0" || fields[2] == "HTTP/1.1" else { throw ClientError.invalidResponse }
        return try callback("http://127.0.0.1:\(port)" + fields[1])
    }
}

@MainActor
final class ProviderAuthCallbackListener {
    private let request: CodexAuthorizationRequest
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var continuation: CheckedContinuation<String, Error>?
    private var deadline: Task<Void, Never>?
    private var received = false
    private var opened = false

    init(request: CodexAuthorizationRequest) { self.request = request }

    func receive(openPage: @escaping @MainActor (URL) -> Bool) async throws -> String {
        try Task.checkCancellation()
        guard listener == nil, !opened, let port = NWEndpoint.Port(rawValue: request.port) else { throw ClientError.invalidResponse }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in self?.listenerChanged(state, openPage: openPage) }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in self?.accept(connection) }
                }
                listener.start(queue: .main)
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(300)) }
                    catch { return }
                    self?.finish(.failure(ClientError.message("Sign-in expired. Start a new sign-in.")))
                }
                if Task.isCancelled { finish(.failure(CancellationError())) }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.finish(.failure(CancellationError())) }
        }
    }

    private func listenerChanged(_ state: NWListener.State, openPage: @MainActor (URL) -> Bool) {
        guard continuation != nil else { return }
        switch state {
        case .ready where !opened:
            guard listener?.port?.rawValue == request.port else {
                finish(.failure(ClientError.message("Could not listen on the sign-in callback port.")))
                return
            }
            opened = true
            if !openPage(request.page) { finish(.failure(ClientError.message("Could not open the sign-in page."))) }
        case .failed, .cancelled:
            finish(.failure(ClientError.message("Could not listen for sign-in on this Mac. Cancel and start a new sign-in.")))
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard continuation != nil, connections.count < 8, !received else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: .main)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, ended, error in
            Task { @MainActor in
                guard let self, self.continuation != nil else { connection.cancel(); return }
                var combined = buffer
                if let data { combined.append(data) }
                if combined.count > 24_576 {
                    self.respond(connection, code: "400 Bad Request", body: "Invalid sign-in response.")
                } else if let end = combined.range(of: Data("\r\n\r\n".utf8)) {
                    do {
                        guard !self.received else { throw ClientError.invalidResponse }
                        let callback = try self.request.callback(request: combined.prefix(upTo: end.lowerBound))
                        self.received = true
                        self.respond(connection, code: "200 OK", body: "Return to T3 Code to finish signing in.", callback: callback)
                    } catch { self.respond(connection, code: "400 Bad Request", body: "This response does not belong to the active sign-in.") }
                } else if ended || error != nil {
                    self.connections.removeValue(forKey: ObjectIdentifier(connection))
                    connection.cancel()
                } else { self.read(connection, buffer: combined) }
            }
        }
    }

    private func respond(_ connection: NWConnection, code: String, body: String, callback: String? = nil) {
        let response = "HTTP/1.1 \(code)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\n" +
            "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                self?.connections.removeValue(forKey: ObjectIdentifier(connection))
                connection.cancel()
                if let callback { self?.finish(.success(callback)) }
            }
        })
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel()
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        continuation.resume(with: result)
    }
}
