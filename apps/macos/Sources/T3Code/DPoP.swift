import CryptoKit
import Foundation

struct DPoPKey: Sendable {
    private let key: P256.Signing.PrivateKey
    private let jwk: [String: String]
    let thumbprint: String

    init(rawRepresentation: Data? = nil) throws {
        let key = try rawRepresentation.map(P256.Signing.PrivateKey.init(rawRepresentation:)) ?? P256.Signing.PrivateKey()
        let coordinates = key.publicKey.x963Representation.dropFirst()
        let jwk = ["kty": "EC", "crv": "P-256", "x": Self.base64URL(coordinates.prefix(32)),
                   "y": Self.base64URL(coordinates.suffix(32))]
        self.key = key
        self.jwk = jwk
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        thumbprint = Self.base64URL(Data(SHA256.hash(data: try encoder.encode(jwk))))
    }

    var rawRepresentation: Data { key.rawRepresentation }

    func proof(method: String, url: URL, accessToken: String? = nil, now: Date = .now) throws -> String {
        guard var destination = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = destination.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = destination.host, !host.isEmpty, destination.user == nil, destination.password == nil else {
            throw ClientError.invalidResponse
        }
        destination.scheme = scheme
        destination.host = host.lowercased()
        if destination.port == (scheme == "https" ? 443 : 80) { destination.port = nil }
        if destination.path.isEmpty { destination.path = "/" }
        destination.query = nil
        destination.fragment = nil
        guard let htu = destination.url?.absoluteString else { throw ClientError.invalidResponse }
        let header: Wire = .object(["typ": .string("dpop+jwt"), "alg": .string("ES256"),
                                    "jwk": .object(jwk.mapValues(Wire.string))])
        var claims: Payload = ["htm": .string(method.uppercased()), "htu": .string(htu),
                               "jti": .string(UUID().uuidString.lowercased()),
                               "iat": .int(Int(now.timeIntervalSince1970.rounded(.down)))]
        if let accessToken { claims["ath"] = .string(Self.base64URL(Data(SHA256.hash(data: Data(accessToken.utf8))))) }
        let encoder = JSONEncoder()
        let segments = Self.base64URL(try encoder.encode(header)) + "." + Self.base64URL(try encoder.encode(Wire.object(claims)))
        let signature = try key.signature(for: Data(segments.utf8))
        return segments + "." + Self.base64URL(signature.rawRepresentation)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
