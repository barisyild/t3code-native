import Foundation
import Testing
@testable import T3Code

struct GuestShareTests {
    @Test func projectionKeepsOnlyWaitingMessagesAndDropsThemOnClose() throws {
        let image: Wire = .object([
            "type": .string("image"), "id": .string("image"), "name": .string("reference.png"),
            "mimeType": .string("image/png"), "sizeBytes": .int(40),
        ])
        let messages: [Wire] = [
            .object(["id": .string("waiting"), "status": .string("pending"), "text": .string(""), "attachments": .array([image])]),
            .object(["id": .string("sent"), "status": .string("sent"), "text": .string("Sent text")]),
            .object(["id": .string("dismissed"), "status": .string("dismissed"), "text": .string("Dismissed text")]),
        ]
        var detail = ThreadDetail()
        detail.apply(.object([
            "kind": .string("snapshot"), "snapshotSequence": .int(4),
            "projection": .object(["thread": .object(["guestShare": share(name: "Sam", messages: messages)])]),
        ]))
        let pending = try #require(detail.guestShare?.pending.first)
        #expect(detail.guestShare?.guestName == "Sam")
        #expect(detail.guestShare?.pending.map(\.id) == ["waiting"])
        #expect(pending.text == "")
        #expect(pending.attachments.first?.name == "reference.png")

        detail.apply(event(.null, sequence: 6))
        detail.apply(event(share(name: "Sam", messages: messages), sequence: 5))
        #expect(detail.guestShare == nil)
    }

    @Test func invitationFollowsItsExactUnredeemedShare() throws {
        let link = "https://env.t3.test/guest#test-invite"
        let unredeemed = share(name: nil, messages: [])
        let invite = try #require(GuestShareInvitation(.object(["url": .string(link), "share": unredeemed])))
        let expiry = try #require(WorkspaceStyle.date("2026-11-12T10:00:00.000Z"))
        let before = expiry.addingTimeInterval(-1)
        #expect(invite.isAvailable(for: GuestShare(unredeemed), at: before))
        #expect(!invite.isAvailable(for: GuestShare(unredeemed), at: expiry))
        #expect(!invite.isAvailable(for: GuestShare(share(name: "Sam", messages: [])), at: before))
        #expect(!invite.isAvailable(for: GuestShare(share(id: "replacement", name: nil, messages: [])), at: before))
        #expect(!invite.isAvailable(for: nil, at: before))
        #expect(GuestShareInvitation(.object(["url": .string("https://other.t3.test/guest#test-invite"), "share": unredeemed])) == nil)
    }

    @Test func boundedMessageHydrationKeepsGuestAttribution() throws {
        let context: Wire = .object(["guest": .object([
            "guestMessageId": .string("guest-message"), "name": .string("Sam"), "text": .string("What changed?"),
        ])])
        let message: Wire = .object([
            "id": .string("message"), "text": .string("Message from guest Sam, sent by the owner:\n\nWhat changed?"), "context": context,
        ])
        let item: Wire = .object([
            "id": .string("item"), "threadId": .string("thread"), "ordinal": .int(2), "type": .string("user_message"),
            "messageId": .string("message"), "textOmitted": .bool(true),
        ])
        let wholeItem = Wire.object((item.object ?? [:]).merging([
            "id": .string("second-item"), "ordinal": .int(3), "textOmitted": .bool(false),
            "text": message["text"], "context": .null,
        ]) { _, next in next })
        var detail = ThreadDetail()
        detail.apply(.object(["kind": .string("snapshot"), "snapshotSequence": .int(9), "projection": .object([
            "messages": .array([message]),
            "visibleTurnItems": .array([item, wholeItem].map { .object(["item": $0, "visibility": .string("local")]) }),
        ])]))
        #expect(detail.timeline.compactMap { $0.guest?.name } == ["Sam", "Sam"])
        #expect(detail.timeline.compactMap { $0.guest?.text } == ["What changed?", "What changed?"])
        let queued = try #require(QueuedMessage(run: .object(["id": .string("run")]), message: message))
        #expect(queued.guestName == "Sam")
        #expect(queued.displayText == "What changed?")
        #expect(!queued.editable)
    }

    private func share(id: String = "share", name: String?, messages: [Wire]) -> Wire {
        .object(["id": .string(id), "host": .string("env.t3.test"), "expiresAt": .string("2026-11-12T10:00:00.000Z"),
                 "guestName": name.map(Wire.string) ?? .null, "messages": .array(messages)])
    }

    private func event(_ value: Wire, sequence: Int) -> Wire {
        .object(["kind": .string("event"), "sequence": .int(sequence), "event": .object([
            "type": .string("thread.guest-share-updated"), "payload": .object(["guestShare": value]),
        ])])
    }
}
