import Foundation
import Testing
@testable import T3Code

struct DeviceTests {
    @Test func devicesAndSessionsAreScopedByHost() throws {
        let state = try #require(DeviceState(.object([
            "revision": .int(3), "hostStatus": .string("ready"), "hubBasePath": .string("/api/device-hub"),
            "hosts": .array([host("local", kind: "local")]),
            "easHosts": .array([host("eas", kind: "eas")]),
            "simlockHosts": .array([host("cloud", kind: "simlock")]),
            "devices": .array([device("local", field: "id"), device("cloud", field: "id")]),
            "sessions": .array([device("cloud", field: "deviceId")]),
            "bootingDevices": .array([device("local", field: "id")]),
        ])))
        #expect(state.hosts.map(\.kind) == [.local, .eas, .simlock])
        let session = try #require(state.sessions.first)
        let booting = try #require(state.bootingDevices.first)
        #expect(state.device(session.key)?.key.hostID == "cloud")
        #expect(state.device(booting.key)?.key.hostID == "local")
        #expect(session.key != booting.key)
    }

    @Test func framesCanSpanChunksWithoutLosingTheNextFrame() throws {
        var avcc = DeviceAVCCReader()
        #expect(try avcc.append(Data([0, 0, 0])).isEmpty)
        #expect(try avcc.append(Data([3, 4, 1])).isEmpty)
        let frames = try avcc.append(Data([2, 0, 0, 0, 2, 2, 3]))
        #expect(frames.map(\.kind) == [.seed, .keyframe])
        #expect(frames.map(\.bytes) == [Data([1, 2]), Data([3])])
        #expect(throws: DeviceMediaFailure.self) { try avcc.append(Data([0, 128, 0, 1])) }

        var mjpeg = try #require(DeviceJPEGReader(contentType: "multipart/x-mixed-replace; boundary=\"fixture\""))
        let firstPart = Data("--fixture\r\nContent-Type: image/jpeg\r\nContent-Length: 3\r\n\r\nA".utf8)
        #expect(try mjpeg.append(firstPart).isEmpty)
        let rest = Data("BC\r\n--fixture\r\nContent-Type: image/jpeg\r\n\r\nDEF\r\n--fixture".utf8)
        #expect(try mjpeg.append(rest) == [Data("ABC".utf8), Data("DEF".utf8)])

        var part = try #require(DeviceJPEGReader(contentType: "image/jpeg"))
        #expect(try part.append(Data([0xff, 0xd8, 0xff])).isEmpty)
        #expect(try part.append(Data([0xd9])) == [Data([0xff, 0xd8, 0xff, 0xd9])])
    }

    @Test func androidVideoAcceptsSEMUHeadersAndWaitsForTheFirstKeyframe() throws {
        let initial = Data([
            0, 0, 0, 1, 0x67, 0x42, 0xc0, 0x0a, 0xda, 0x27, 0xb0, 0x11, 0, 0, 3, 0,
            1, 0, 0, 3, 0, 4, 0x0f, 0x12, 0x26, 0xa0, 0, 0, 0, 1, 0x68, 0xce, 0x0f, 0xc8,
            0, 0, 1, 0x65, 0x88, 0x84, 0x3a, 0x11, 0x8a, 0, 2, 2, 0xb1, 0xc0, 0, 0x40,
            0xaa, 0x38, 0, 8, 0x14, 0xc9, 0xd7, 0x5d, 0x75, 0xe0,
        ])
        let delta = Data([0, 0, 0, 1, 0x41, 0x9a, 0x20, 0x12, 0xa3, 0xc0])
        let header = Data([0x53, 0x45, 0x4d, 0x55, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        var decoder = DeviceH264()
        #expect(try decoder.annexB(delta) == nil)
        let initialSample = try decoder.annexB(header + initial)
        let first = try #require(initialSample)
        #expect(first.keyframe)
        #expect(first.size == CGSize(width: 32, height: 48))
        let deltaSample = try decoder.annexB(delta)
        let following = try #require(deltaSample)
        #expect(!following.keyframe)
    }

    @Test func mediaRoutesKeepHostAndDeviceIDsSeparateFromTheEnvironmentOrigin() throws {
        let key = try #require(DeviceKey(.object(["hostId": .string("host & A"), "id": .string("iPhone/1 ?")]), field: "id"))
        let scope = DeviceScope(environmentID: "test", connection: UUID(), threadID: "test")
        let origin = try #require(URL(string: "https://relay.example:433/path?old=1#fragment"))
        let target = DeviceTarget(scope: scope, key: key, platform: .ios, hostKind: .ssh)
        let access = DeviceMediaAccess(origin: origin, target: target, ticket: "media-ticket")
        let avccURL = try #require(access.request(.avcc).url)
        let avcc = try #require(URLComponents(url: avccURL, resolvingAgainstBaseURL: false))
        #expect(avcc.percentEncodedPath == "/api/device-hub/vendor/serve-sim/helper/iPhone%2F1%20%3F/stream.avcc")
        #expect(avcc.port == 433 && avcc.fragment == nil)
        #expect(avcc.queryItems == [.init(name: "hostId", value: key.hostID), .init(name: "wsTicket", value: "media-ticket")])
        let android = DeviceTarget(scope: scope, key: key, platform: .android, hostKind: .local)
        let socket = try DeviceMediaAccess(origin: origin, target: android, ticket: "media-ticket").request(.input(video: true))
        let socketURL = try #require(socket.url)
        let endpoint = try #require(URLComponents(url: socketURL, resolvingAgainstBaseURL: false))
        #expect(endpoint.scheme == "wss" && endpoint.path == "/api/device-hub/vendor/serve-emu/ws")
        #expect(endpoint.queryItems?.contains(.init(name: "frame-meta", value: "1")) == true)
    }

    @Test func rotatedPortraitTouchCoordinatesMapBackToTheDevice() throws {
        let screen = try #require(DeviceScreenConfig(.object([
            "width": .int(400), "height": .int(800), "orientation": .string("landscape_left"),
        ])))
        #expect(screen.rawPoint(CGPoint(x: 0.25, y: 0.5)) == CGPoint(x: 0.5, y: 0.75))
    }

    private func host(_ id: String, kind: String) -> Wire {
        .object(["id": .string(id), "kind": .string(kind), "label": .string(id)])
    }

    private func device(_ hostID: String, field: String) -> Wire {
        .object(["hostId": .string(hostID), field: .string("shared-id"), "platform": .string("ios"),
                 "name": .string("Fixture Phone"), "threadId": .string("thread")])
    }
}
