import Foundation

@MainActor
final class McpAppSession {
    typealias Request = @MainActor (String, Payload) async throws -> Wire
    typealias Approval = @MainActor (String, String) async throws -> Bool

    let page: McpAppPage
    let conversationID: String
    private let isConnected: () -> Bool
    private let request: Request
    private let sendMessage: @MainActor (String) async throws -> Void

    init(page: McpAppPage, conversationID: String, isConnected: @escaping () -> Bool, request: @escaping Request,
         sendMessage: @escaping @MainActor (String) async throws -> Void) {
        self.page = page
        self.conversationID = conversationID
        self.isConnected = isConnected
        self.request = request
        self.sendMessage = sendMessage
    }

    func requireConnection() throws {
        try Task.checkCancellation()
        guard isConnected() else { throw ClientError.disconnected }
    }

    func toolCall() async throws -> Wire {
        var fields: Payload = [:]
        if let revision = page.revision { fields["revision"] = .string(revision) }
        let item = try await scopedRequest("orchestration.getTurnItem", fields)["item"]
        guard item["type"].string == "dynamic_tool" else { throw ClientError.invalidResponse }
        var call: Payload = ["arguments": item["input"]]
        if item["output"]["result"] != .null { call["result"] = item["output"]["result"] }
        return .object(call)
    }

    func toolDefinition() async throws -> Wire {
        try await scopedRequest("mcpApps.toolInfo", ["name": .string(page.tool)])["tool"]
    }

    func callTool(_ params: Wire, approve: Approval, requireActive: () throws -> Void) async throws -> Wire {
        let name = try params.requireString("name")
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let arguments = params["arguments"].object else {
            throw ClientError.invalidResponse
        }
        let info = try await scopedRequest("mcpApps.toolInfo", ["name": .string(name)])
        try requireActive()
        guard info["callable"].bool == true else { throw ClientError.message("This app cannot call that tool.") }
        if info["readOnly"].bool != true {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let detail = String(decoding: try encoder.encode(Wire.object(arguments)), as: UTF8.self)
            let title = info["title"].string ?? name
            guard try await approve("Allow \(page.server) to run \(title)?", detail) else {
                throw ClientError.message("Declined by the user.")
            }
        }
        try requireActive()
        return try await scopedRequest("mcpApps.callTool", ["name": .string(name), "arguments": .object(arguments)])
    }

    func readResource(_ params: Wire) async throws -> Wire {
        try await scopedRequest("mcpApps.readResource", ["uri": .string(try params.requireString("uri"))])
    }

    func updateModelContext(_ params: Wire) async throws -> Wire {
        var fields: Payload = ["conversationThreadId": .string(conversationID)]
        if case .array = params["content"] { fields["content"] = params["content"] }
        if case .object = params["structuredContent"] { fields["structuredContent"] = params["structuredContent"] }
        return try await scopedRequest("mcpApps.updateModelContext", fields)
    }

    func send(_ params: Wire, approve: Approval, requireActive: () throws -> Void) async throws {
        let text = try params.requireString("text")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientError.invalidResponse }
        guard try await approve("Send a message from \(page.server)?", text) else {
            throw ClientError.message("Declined by the user.")
        }
        try requireActive()
        try requireConnection()
        try await sendMessage(text)
    }

    func downloadBytes(_ file: Wire) async throws -> Data {
        let bytes: Data?
        if file["_tag"].string == "embedded" {
            bytes = file["base64"].string.flatMap { Data(base64Encoded: $0) }
        } else if file["_tag"].string == "link" {
            let resource = try await readResource(file)["contents"].array.first ?? .null
            if let text = resource["text"].string { bytes = Data(text.utf8) }
            else { bytes = resource["blob"].string.flatMap { Data(base64Encoded: $0) } }
        } else { throw ClientError.invalidResponse }
        guard let bytes else { throw ClientError.message("The resource has no contents.") }
        guard bytes.count <= 25 * 1024 * 1024 else { throw ClientError.message("The resource is too large to save.") }
        return bytes
    }

    private func scopedRequest(_ method: String, _ fields: Payload) async throws -> Wire {
        try requireConnection()
        var payload = fields
        payload["threadId"] = .string(page.threadID)
        payload["itemId"] = .string(page.itemID)
        let result = try await request(method, payload)
        try requireConnection()
        return result
    }
}
