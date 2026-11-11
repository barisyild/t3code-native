import Foundation
import Testing
@testable import T3Code

struct AttachmentTests {
    @Test func storedAttachmentsKeepTheirIdentityAndExportSafeFilenames() throws {
        let image = try #require(ChatAttachment(.object([
            "id": .string("stored-image"), "type": .string("image"), "name": .string("../screens/design.png"),
            "mimeType": .string("image/png"), "sizeBytes": .int(24),
        ])))
        #expect(image.id == "stored-image")
        #expect(image.fileName == "design.png")
        #expect(image.isImage)
        #expect(image.resource["_tag"].string == "attachment")
        #expect(image.resource["attachmentId"].string == "stored-image")
        #expect(image.resource["fileName"].string == "../screens/design.png")
        #expect(image.resource["disposition"].string == "inline")
        let unicode = try #require(ChatAttachment(.object([
            "id": .string("unicode"), "type": .string("image"), "name": .string(String(repeating: "🚀", count: 100) + ".png"),
            "mimeType": .string("image/png"), "sizeBytes": .int(24),
        ])))
        #expect(unicode.fileName.utf8.count <= 220)
        #expect(unicode.fileName.hasSuffix(".png"))
        let future = try #require(ChatAttachment(.object([
            "id": .string("future"), "type": .string("future-type"), "name": .string("record"),
            "mimeType": .string("application/octet-stream"), "sizeBytes": .int(1),
        ])))
        #expect(!future.isSupported)
        #expect(ChatAttachment(.object([
            "id": .string("invalid"), "type": .string("file"), "name": .string("empty.txt"),
            "mimeType": .string("text/plain"), "sizeBytes": .int(0),
        ])) == nil)
    }

    @Test func signedAssetRequestsStayOnTheEnvironmentAndCarryNoSessionCredential() throws {
        let api = EnvironmentAPI(origin: try #require(URL(string: "https://environment.example.test")), token: "session-secret")
        let request = try api.assetRequest("/api/assets/signed-grant/design%20review.png?download=1")
        #expect(request.url?.absoluteString == "https://environment.example.test/api/assets/signed-grant/design%20review.png?download=1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "DPoP") == nil)
        for path in ["https://other.example.test/api/assets/grant/file", "//other.example.test/api/assets/grant/file",
                     "/oauth/token", "/api/assets/../../oauth/token", "/api/assets/%2e%2e/oauth/token"] {
            #expect(throws: ClientError.self) { try api.assetRequest(path) }
        }
    }

    @Test func exportingAnAttachmentReplacesTheDestinationAndPreservesTheSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let download = directory.appendingPathComponent("download")
        let contents = Data("Complete attachment contents\n".utf8)
        try contents.write(to: download)
        let file = try AttachmentFile(temporaryFile: download, name: "notes.txt")
        let destination = directory.appendingPathComponent("saved.txt")
        try Data("Previous contents".utf8).write(to: destination)
        try file.export(to: destination)
        #expect(try Data(contentsOf: destination) == contents)
        #expect(try Data(contentsOf: file.url) == contents)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["saved.txt"])
    }

    @MainActor @Test func aLateDownloadCannotPopulateAChangedEnvironment() async throws {
        let attachment = try #require(ChatAttachment(.object([
            "id": .string("file"), "type": .string("file"), "name": .string("example.txt"),
            "mimeType": .string("text/plain"), "sizeBytes": .int(7),
        ])))
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("example".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let (started, signalStarted) = AsyncStream<Void>.makeStream()
        let (release, signalRelease) = AsyncStream<Void>.makeStream()
        defer { signalStarted.finish(); signalRelease.finish() }
        let first = AttachmentScope(environmentID: "first", connection: UUID())
        let second = AttachmentScope(environmentID: "second", connection: UUID())
        let store = AttachmentStore { _, _ in
            signalStarted.yield(())
            for await _ in release { break }
            return try AttachmentFile(temporaryFile: source, name: "example.txt")
        }
        store.setScope(first)
        let download = Task { try await store.file(attachment, scope: first) }
        var milestone = started.makeAsyncIterator()
        _ = await milestone.next()
        store.setScope(second)
        signalRelease.yield(())
        await #expect(throws: ClientError.self) { try await download.value }
        #expect(store.scope == second)
    }
}
