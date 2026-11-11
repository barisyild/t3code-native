import CryptoKit
import Foundation
import Testing
@testable import T3Code

struct ManagedRelayTests {
    @Test func proofsSignTheHTTPAuthorityAndBindThePresentedCredential() throws {
        let key = try DPoPKey()
        let endpoint = try #require(URL(string: "HTTPS://Engine.Example.test:443/ws?ticket=secret#fragment"))
        let proof = try key.proof(method: "get", url: endpoint, accessToken: "fixture-ticket",
                                  now: Date(timeIntervalSince1970: 1_800_000_000))
        let claims = try verify(proof, method: "GET", htu: "https://engine.example.test/ws", credential: "fixture-ticket",
                                thumbprint: key.thumbprint)
        #expect(claims["iat"].int == 1_800_000_000)
        #expect(claims["jti"].string != nil)
        let restored = try DPoPKey(rawRepresentation: key.rawRepresentation)
        #expect(restored.thumbprint == key.thumbprint)
    }

    @Test func aRejectedHTTPTokenRenewsWithoutReplacingTheSignedRPCURL() async throws {
        let fixture = RelayFixture()
        let relay = try makeRelay(fixture)
        let environments = try await relay.environments(accountID: "account")
        let saved = try #require(environments.first)
        let route = try #require(saved.relay)
        #expect(try await relay.status(route) == "online")
        let connected = try await relay.connect(route)
        let api = EnvironmentAPI(origin: connected.access.endpoint.origin, relay: connected.access, transport: fixture.handle)
        let socket = try await api.socketURL()
        let socketURL = try #require(URLComponents(url: socket, resolvingAgainstBaseURL: false))
        #expect(socketURL.scheme == "wss")
        #expect(socketURL.host == "engine.example.test")
        #expect(socketURL.path == "/ws")
        let parameters = Dictionary(uniqueKeysWithValues: (socketURL.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(parameters["connectionMethod"] == "relay")
        #expect(parameters["wsTicket"] == "fixture-ticket")
        #expect(parameters["clientCapabilities"] == "settingsSecretReferences")
        let upgrade = try #require(parameters["dpop"])
        _ = try verify(upgrade, method: "GET", htu: "https://engine.example.test/ws",
                       credential: "fixture-ticket", thumbprint: try #require(await fixture.thumbprint))
        let diff = try await api.http("/api/pull-requests/diff", method: "POST", body: Data("{}".utf8), contentType: "application/json")
        #expect(diff["patch"].string == "fixture diff")
        #expect(await fixture.environmentMints == 2)
        #expect(await fixture.relayMints == 1)
        #expect(await fixture.socketTickets == 1)
        #expect(await fixture.diffAttempts == ["environment-1", "environment-2"])
    }

    @Test func aMismatchedDescriptorNeverReceivesTheBootstrapCredential() async throws {
        let fixture = RelayFixture(descriptorID: "other-environment")
        let relay = try makeRelay(fixture)
        let saved = try #require(try await relay.environments(accountID: "account").first)
        await #expect(throws: ClientError.self) {
            _ = try await relay.connect(try #require(saved.relay))
        }
        #expect(await fixture.environmentMints == 0)
    }

    @Test func endpointCannotMoveTheProofToAnotherAuthority() {
        let mixed: Wire = .object(["httpBaseUrl": .string("https://engine.example.test"),
                                   "wsBaseUrl": .string("wss://other.example.test/ws")])
        #expect(RelayEndpoint(mixed) == nil)
        #expect(RelayEndpoint.secureOrigin("https://user@engine.example.test") == nil)
        #expect(RelayEndpoint.secureOrigin("http://engine.example.test") == nil)
    }

    @Test func linkCallsUseAccountAuthorizationAndMatchTheRequestedEnvironment() async throws {
        let fixture = RelayFixture()
        let relay = try makeRelay(fixture)
        let challenge = try await relay.linkChallenge(.tunnel, accountID: "account")
        #expect(challenge == "fixture-challenge")
        let configuration = try await relay.linkEnvironment(.tunnel, proof: "fixture-proof", serverID: "environment", accountID: "account")
        #expect(configuration["environmentCredential"] == .string("fixture-environment-credential"))
        #expect(configuration["relayUrl"] == .string("https://relay.example.test"))
        #expect(configuration["endpointRuntime"]?["providerKind"].string == "cloudflare_tunnel")
        await #expect(throws: ClientError.self) {
            _ = try await relay.linkEnvironment(.tunnel, proof: "fixture-proof", serverID: "wrong-environment", accountID: "account")
        }
        await #expect(throws: ClientError.self) {
            _ = try await relay.linkEnvironment(.activity, proof: "fixture-proof", serverID: "environment", accountID: "account")
        }
        try await relay.unlinkEnvironment(serverID: "environment", accountID: "account")
        #expect(await fixture.linkRemovals == 1)
        #expect(await fixture.relayMints == 0)
    }
}

private func makeRelay(_ fixture: RelayFixture) throws -> ManagedRelayClient {
    let origin = try #require(RelayEndpoint.secureOrigin("https://relay.example.test/"))
    return ManagedRelayClient(origin: origin, persistent: false, transport: fixture.handle) { account in
        #expect(account == "account")
        return "fixture-cloud-subject"
    }
}

private actor RelayFixture {
    private let descriptorID: String
    private let endpoint: Wire = .object([
        "httpBaseUrl": .string("https://engine.example.test"), "wsBaseUrl": .string("wss://engine.example.test"),
        "providerKind": .string("t3_relay"),
    ])
    private(set) var thumbprint: String?
    private(set) var environmentMints = 0
    private(set) var relayMints = 0
    private(set) var socketTickets = 0
    private(set) var linkRemovals = 0
    private(set) var diffAttempts: [String] = []

    init(descriptorID: String = "environment") { self.descriptorID = descriptorID }

    func handle(_ request: URLRequest) async throws -> Wire {
        let url = try #require(request.url)
        let route = (url.host() ?? "") + url.path()
        switch route {
        case "relay.example.test/v1/environments":
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-cloud-subject")
            return .object(["environments": .array([.object([
                "environmentId": .string("environment"), "label": .string("Fixture Mac"), "endpoint": endpoint,
            ])])])
        case "relay.example.test/v1/client/dpop-token":
            let params = form(request)
            #expect(params["subject_token"] == "fixture-cloud-subject")
            #expect(params["resource"] == "https://relay.example.test")
            #expect(params["client_id"] == "t3-web")
            let proof = try #require(request.value(forHTTPHeaderField: "DPoP"))
            let keyID = try jwkThumbprint(proof)
            _ = try verify(proof, method: "POST", htu: url.absoluteString, credential: nil, thumbprint: keyID)
            thumbprint = keyID
            relayMints += 1
            return .object(["token_type": .string("DPoP"), "access_token": .string("relay-1"), "expires_in": .int(300),
                            "scope": .string("environment:status environment:connect")])
        case "relay.example.test/v1/client/environment-link-challenges":
            let fields = try JSONDecoder().decode(Wire.self, from: try #require(request.httpBody))
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-cloud-subject")
            #expect(fields == .object(T3ConnectLinkMode.tunnel.permissions))
            return .object(["challenge": .string("fixture-challenge")])
        case "relay.example.test/v1/client/environment-links":
            let fields = try JSONDecoder().decode(Wire.self, from: try #require(request.httpBody))
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-cloud-subject")
            #expect(fields["proof"].string == "fixture-proof")
            return .object([
                "ok": .bool(true), "environmentId": .string("environment"), "cloudUserId": .string("user"),
                "relayIssuer": .string("https://relay.example.test"), "environmentCredential": .string("fixture-environment-credential"),
                "cloudMintPublicKey": .string("fixture-mint-key"), "endpoint": .object([
                    "httpBaseUrl": .string("https://engine.example.test"), "wsBaseUrl": .string("wss://engine.example.test"),
                    "providerKind": .string("cloudflare_tunnel"),
                ]), "endpointRuntime": .object(["providerKind": .string("cloudflare_tunnel"), "connectorToken": .string("fixture-connector")]),
            ])
        case "relay.example.test/v1/client/environment-links/environment":
            #expect(request.httpMethod == "DELETE")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-cloud-subject")
            linkRemovals += 1
            return .object(["ok": .bool(true)])
        case "relay.example.test/v1/environments/environment/status":
            try check(request, token: "relay-1")
            return .object(["environmentId": .string("environment"), "status": .string("online")])
        case "relay.example.test/v1/environments/environment/connect":
            try check(request, token: "relay-1")
            let value = try JSONDecoder().decode(Wire.self, from: try #require(request.httpBody))
            #expect(value["clientProofKeyThumbprint"].string == thumbprint)
            return .object(["environmentId": .string("environment"), "endpoint": endpoint,
                            "credential": .string("bootstrap-\(environmentMints + 1)")])
        case "engine.example.test/.well-known/t3/environment":
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return .object(["environmentId": .string(descriptorID), "label": .string("Fixture Mac")])
        case "engine.example.test/oauth/token":
            try check(request, token: nil)
            #expect(form(request)["subject_token"] == "bootstrap-\(environmentMints + 1)")
            environmentMints += 1
            return .object(["token_type": .string("DPoP"), "access_token": .string("environment-\(environmentMints)"), "expires_in": .int(3600)])
        case "engine.example.test/api/auth/websocket-ticket/rpc":
            try check(request, token: "environment-\(environmentMints)")
            socketTickets += 1
            return .object(["ticket": .string("fixture-ticket")])
        case "engine.example.test/api/pull-requests/diff":
            let token = "environment-\(environmentMints)"
            try check(request, token: token)
            diffAttempts.append(token)
            if diffAttempts.count == 1 { throw ClientError.http(401, nil) }
            return .object(["patch": .string("fixture diff")])
        default:
            throw ClientError.message("Unexpected fixture request \(route)")
        }
    }

    private func check(_ request: URLRequest, token: String?) throws {
        #expect(request.value(forHTTPHeaderField: "Authorization") == token.map { "DPoP \($0)" })
        _ = try verify(try #require(request.value(forHTTPHeaderField: "DPoP")), method: try #require(request.httpMethod),
                       htu: try #require(request.url).absoluteString, credential: token, thumbprint: try #require(thumbprint))
    }

    private func form(_ request: URLRequest) -> [String: String] {
        var parts = URLComponents()
        parts.percentEncodedQuery = request.httpBody.map { String(decoding: $0, as: UTF8.self) }
        return Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
}

private func jwkThumbprint(_ proof: String) throws -> String {
    let header = try JSONDecoder().decode(Wire.self, from: unbase64(try #require(proof.split(separator: ".").first)))
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return base64(Data(SHA256.hash(data: try encoder.encode(header["jwk"]))))
}

private func verify(_ proof: String, method: String, htu: String, credential: String?, thumbprint: String) throws -> Wire {
    let segments = proof.split(separator: ".")
    try #require(segments.count == 3)
    let header = try JSONDecoder().decode(Wire.self, from: unbase64(segments[0]))
    let claims = try JSONDecoder().decode(Wire.self, from: unbase64(segments[1]))
    let jwk = header["jwk"]
    #expect(header["typ"].string == "dpop+jwt")
    #expect(header["alg"].string == "ES256")
    #expect(jwk["kty"].string == "EC")
    #expect(jwk["crv"].string == "P-256")
    #expect(try jwkThumbprint(proof) == thumbprint)
    let x = try unbase64(Substring(try jwk.requireString("x")))
    let y = try unbase64(Substring(try jwk.requireString("y")))
    let publicKey = try P256.Signing.PublicKey(x963Representation: Data([4]) + x + y)
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: unbase64(segments[2]))
    #expect(publicKey.isValidSignature(signature, for: Data(segments.prefix(2).joined(separator: ".").utf8)))
    #expect(claims["htm"].string == method)
    #expect(claims["htu"].string == htu)
    #expect(claims["ath"].string == credential.map { base64(Data(SHA256.hash(data: Data($0.utf8)))) })
    return claims
}

private func base64(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

private func unbase64(_ value: Substring) throws -> Data {
    let text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    return try #require(Data(base64Encoded: text + String(repeating: "=", count: (4 - text.count % 4) % 4)))
}
