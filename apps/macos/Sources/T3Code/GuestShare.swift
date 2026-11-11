import Foundation

struct GuestMessage: Equatable, Sendable {
    enum Decision { case send, dismiss }

    let id: String
    let text: String
    let attachments: [ChatAttachment]

    init?(_ value: Wire) {
        guard value["status"].string == "pending", let id = value["id"].string,
              let text = value["text"].string else { return nil }
        self.id = id
        self.text = text
        attachments = value["attachments"].array.compactMap(ChatAttachment.init)
    }
}

struct GuestAttribution: Equatable, Sendable {
    let name: String
    let text: String

    init?(_ context: Wire) {
        guard let name = context["guest"]["name"].string, let text = context["guest"]["text"].string else { return nil }
        self.name = name
        self.text = text
    }
}

struct GuestShare: Equatable, Sendable {
    let id: String
    let host: String
    let expiresAt: Date
    let guestName: String?
    let pending: [GuestMessage]

    init?(_ value: Wire) {
        guard let id = value["id"].string, let host = value["host"].string,
              let expiry = WorkspaceStyle.date(value["expiresAt"].string) else { return nil }
        self.id = id
        self.host = host
        expiresAt = expiry
        guestName = value["guestName"].string
        pending = value["messages"].array.compactMap(GuestMessage.init)
    }

    func status(at now: Date) -> String {
        if expiresAt <= now { return "Guest link expired" }
        if let guestName { return "\(guestName) is a guest" }
        return "Guest link active"
    }
}

struct GuestShareInvitation: Sendable {
    let shareID: String
    let url: URL

    init?(_ response: Wire) {
        guard let share = GuestShare(response["share"]), let raw = response["url"].string,
              let url = URL(string: raw), url.scheme == "https", url.host() == share.host, url.path() == "/guest",
              url.user() == nil, url.password() == nil, url.fragment()?.isEmpty == false else { return nil }
        shareID = share.id
        self.url = url
    }

    func isAvailable(for share: GuestShare?, at now: Date) -> Bool {
        guard let share else { return false }
        return share.id == shareID && share.guestName == nil && share.expiresAt > now
    }
}

struct GuestShareTarget: Equatable {
    let threadID: String
    let connection: UUID
}

extension Workspace {
    var canCreateGuestShare: Bool {
        guestSharingEnabled == true && !sharingConfiguration.blocksConnect && can("access:write")
    }

    func guestShareTarget(for threadID: String?) -> GuestShareTarget? {
        guard can("orchestration:read"), let threadID, let connection = connectionID,
              let thread = data.threads[threadID], !thread.archived, !thread.isProviderNativeSubagent,
              presentedDetail(for: threadID) != nil else { return nil }
        return .init(threadID: threadID, connection: connection)
    }

    func createGuestShare(_ target: GuestShareTarget) async throws -> GuestShareInvitation {
        guard guestShareTarget(for: target.threadID) == target, canCreateGuestShare else { throw ClientError.disconnected }
        let result = try await request("guestShare.create", ["threadId": .string(target.threadID)])
        guard guestShareTarget(for: target.threadID) == target else { throw ClientError.disconnected }
        guard let invitation = GuestShareInvitation(result) else { throw ClientError.invalidResponse }
        return invitation
    }

    func closeGuestShare(_ target: GuestShareTarget, shareID: String) async throws {
        guard guestShareTarget(for: target.threadID) == target, can("orchestration:operate"),
              presentedDetail(for: target.threadID)?.guestShare?.id == shareID else { throw ClientError.disconnected }
        try await dispatch("thread.guest-share.close", threadId: target.threadID)
    }

    func resolveGuestMessage(_ id: String, shareID: String, decision: GuestMessage.Decision,
                             target: GuestShareTarget) async throws {
        guard guestShareTarget(for: target.threadID) == target, can("orchestration:operate") else {
            throw ClientError.disconnected
        }
        guard let share = presentedDetail(for: target.threadID)?.guestShare, share.id == shareID,
              share.pending.contains(where: { $0.id == id }) else { throw ClientError.message("This guest message is no longer waiting.") }
        let fields: Payload = ["guestMessageId": .string(id)]
        switch decision {
        case .dismiss:
            try await dispatch("thread.guest-message.dismiss", threadId: target.threadID, fields)
        case .send:
            let command = UUID().uuidString.lowercased()
            try await dispatch("message.dispatch", threadId: target.threadID, fields.merging([
                "commandId": .string(command), "messageId": .string(command), "text": .string(""), "attachments": .array([]),
                "dispatchMode": .object(["type": .string("queue_after_active")]), "createdBy": .string("user"),
                "creationSource": .string("web"),
            ]) { _, new in new })
        }
    }
}
