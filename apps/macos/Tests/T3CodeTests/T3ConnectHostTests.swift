import Foundation
import Testing
@testable import T3Code

struct T3ConnectHostTests {
    @Test func linkingUsesTheBootstrappedLocalEndpointAndItsActualPort() throws {
        let relay = try #require(URL(string: "https://relay.example.test"))
        let local = try #require(URL(string: "http://127.0.0.1:52004"))
        let target = T3ConnectHostTarget(connection: UUID(), environmentID: "local", serverID: "server", localOrigin: local)
        let request = try #require(target.linkProof(challenge: "challenge", relay: relay, mode: .tunnel))
        #expect(request["origin"] == .object(["localHttpHost": .string("127.0.0.1"), "localHttpPort": .int(52004)]))
        #expect(request["endpoint"] == .object(["httpBaseUrl": .string(local.absoluteString),
                                                 "wsBaseUrl": .string("ws://127.0.0.1:52004"), "providerKind": .string("cloudflare_tunnel")]))
        for address in ["https://remote.example.test", "http://user@127.0.0.1:52004", "http://127.0.0.1:52004/proxy"] {
            let remote = T3ConnectHostTarget(connection: UUID(), environmentID: "remote", serverID: "server", localOrigin: URL(string: address))
            #expect(remote.linkProof(challenge: "challenge", relay: relay, mode: .tunnel) == nil)
        }
    }

    @Test func tunnelAndPublishingUseTheServerLinkModeIndependently() throws {
        let empty = try #require(T3ConnectHostState(.object(["linked": .bool(false), "publishAgentActivity": .bool(false)])))
        #expect(empty.change(to: empty.desired(.tunnel(true))) == .link(.tunnel))
        #expect(empty.change(to: empty.desired(.activity(true))) == .link(.activity))

        let connected = try #require(T3ConnectHostState(.object([
            "linked": .bool(true), "managedTunnelActive": .bool(true), "publishAgentActivity": .bool(true),
            "holdWebhooksWhileOffline": .bool(true),
        ])))
        #expect(connected.change(to: connected.desired(.tunnel(false))) == .link(.activity))
        #expect(connected.change(to: connected.desired(.activity(false))) == .preferences)
        #expect(connected.desired(.activity(false)).preferences["holdWebhooksWhileOffline"] == nil)
        #expect(connected.desired(.holdWebhooks(false)).preferences == ["publishAgentActivity": .bool(true), "holdWebhooksWhileOffline": .bool(false)])

        let activity = try #require(T3ConnectHostState(.object([
            "linked": .bool(true), "managedTunnelActive": .bool(false), "publishAgentActivity": .bool(true),
        ])))
        #expect(activity.change(to: activity.desired(.activity(false))) == .unlink)
        #expect(activity.change(to: activity.desired(.tunnel(true))) == .link(.tunnel))
        #expect(activity.desired(.tunnel(true)).activity)

        let revoked = try #require(T3ConnectHostState(.object([
            "linked": .bool(true), "managedTunnelActive": .bool(true), "linkRevoked": .bool(true), "publishAgentActivity": .bool(false),
        ])))
        #expect(!revoked.tunnel)
        #expect(revoked.change(to: revoked.desired(.tunnel(true))) == .link(.tunnel))
    }
}
