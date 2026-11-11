import Foundation
import Testing
@testable import T3Code

struct SharingAccessTests {
    @Test func pairingPermissionsFollowTheGrantedScopesAndKeepTerminalReadWithOperate() {
        let state: Wire = .object([
            "permissions": .array(["orchestration:read", "access:write", "terminal:read", "terminal:operate"].map(Wire.string)),
            "scopes": .array([.string("orchestration:operate")]),
        ])
        var permissions = PairingPermissions(granted: PairingScope.grantedBy(state))
        #expect(!permissions.available.contains(.environmentOperate))
        permissions.readOnly()
        #expect(permissions.scopes == ["orchestration:read", "terminal:read"])
        permissions.set(.terminalRead, enabled: false)
        permissions.set(.terminalOperate, enabled: true)
        #expect(permissions.selected.contains(.terminalRead))
        permissions.set(.terminalRead, enabled: false)
        #expect(!permissions.selected.contains(.terminalOperate))
        permissions.set(.filesWrite, enabled: true)
        #expect(!permissions.selected.contains(.filesWrite))
    }

    @Test func pairingLinkKeepsTheCredentialInTheFragmentAndRoundTripsReservedCharacters() throws {
        let address = try #require(PairingAddress("https://Example.test:443/"))
        let link = try #require(address.link(credential: "a+b&c=#😀"))
        #expect(link.query() == nil)
        #expect(link.absoluteString.contains("%2B"))
        let target = try PairingTarget(address: link.absoluteString, code: "")
        #expect(target.credential == "a+b&c=#😀")
        #expect(target.origin == address.origin)
        #expect(PairingAddress("https://user:pass@example.test") == nil)
    }

    @Test func accessEventsKeepOnlyTheCurrentLinksAndClientState() {
        var snapshot = SharingAccessSnapshot()
        let link: Wire = .object(["id": .string("new-link"), "label": .string("QA"), "expiresAt": .string("2026-12-01T08:12:13.000Z")])
        let client: Wire = .object(["sessionId": .string("mac"), "current": .bool(true), "connected": .bool(true)])
        _ = snapshot.receive(event("snapshot", 1, .object(["clientSessions": .array([client])])))
        _ = snapshot.receive(event("pairingLinkUpserted", 2, link))
        #expect(snapshot.links["new-link"]?.label == "QA")
        _ = snapshot.receive(event("pairingLinkRemoved", 3, .object(["id": .string("new-link")])))
        let acceptedStaleLink = snapshot.receive(event("pairingLinkUpserted", 2, link))
        #expect(!acceptedStaleLink)
        #expect(snapshot.links.isEmpty)
        #expect(snapshot.clients["mac"]?.current == true)
        _ = snapshot.receive(event("clientRemoved", 4, .object(["sessionId": .string("mac")])))
        #expect(snapshot.clients.isEmpty)
    }

    private func event(_ type: String, _ revision: Int, _ payload: Wire) -> Wire {
        .object(["version": .int(1), "type": .string(type), "revision": .int(revision), "payload": payload])
    }
}
