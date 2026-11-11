import Foundation
import Testing
@testable import T3Code

@MainActor
struct WorkspaceFileTests {
    private let target = WorkspaceFileTarget(environmentID: "fixture", root: "/workspace", relativePath: "notes.txt")

    @Test func anUndoDuringAWriteIsSavedAfterThatWrite() async throws {
        let connection = UUID()
        let (started, signalStart) = AsyncStream<Void>.makeStream()
        let (release, signalRelease) = AsyncStream<Void>.makeStream()
        defer { signalStart.finish(); signalRelease.finish() }
        var writes: [String] = []
        let editor = WorkspaceFileEditor(target: target, contents: try contents("before"), connection: connection) { text, _ in
            writes.append(text)
            if writes.count == 1 {
                signalStart.yield(())
                for await _ in release { break }
            }
        }
        editor.setAccess(connection: connection, writable: true)
        editor.change("first edit")
        editor.flush()
        try #require(editor.isSaving)
        var milestones = started.makeAsyncIterator()
        _ = try #require(await milestones.next())
        editor.change("before")
        editor.flush()
        #expect(editor.isDirty)
        signalRelease.yield(())
        await editor.waitForWrites()

        #expect(writes == ["first edit", "before"])
        #expect(editor.saved.text == "before")
        #expect(!editor.isDirty)
    }

    @Test func reconnectRequiresAReadAndAChoiceWhenTheServerFileChanged() async throws {
        let originalConnection = UUID()
        let newConnection = UUID()
        var writes: [(String, UUID)] = []
        let editor = WorkspaceFileEditor(target: target, contents: try contents("before"), connection: originalConnection) { text, connection in
            writes.append((text, connection))
        }
        editor.setAccess(connection: originalConnection, writable: true)
        editor.change("local edit")
        editor.setAccess(connection: newConnection, writable: true)
        await editor.flushAndWait()
        #expect(writes.isEmpty)

        editor.invalidateRead()
        editor.setAccess(connection: originalConnection, writable: true)
        await editor.flushAndWait()
        #expect(writes.isEmpty)

        editor.refresh(try contents("server edit"), connection: newConnection)
        editor.setAccess(connection: newConnection, writable: true)
        await editor.flushAndWait()
        #expect(writes.isEmpty)
        #expect(editor.conflict?.text == "server edit")
        #expect(editor.text == "local edit")

        editor.keepEdits()
        await editor.waitForWrites()
        #expect(writes.map(\.0) == ["local edit"])
        #expect(writes.map(\.1) == [newConnection])
        #expect(!editor.isDirty)
    }

    @Test func aReadCanConfirmAnEditWhoseWriteResponseWasLost() async throws {
        let connection = UUID()
        var writes: [String] = []
        let editor = WorkspaceFileEditor(target: target, contents: try contents("before"), connection: connection) { text, _ in
            writes.append(text)
            throw ClientError.disconnected
        }
        editor.setAccess(connection: connection, writable: true)
        editor.change("saved on server")
        await editor.flushAndWait()
        #expect(editor.isDirty)
        #expect(editor.error != nil)

        editor.refresh(try contents("saved on server"), connection: UUID())
        await editor.flushAndWait()
        #expect(writes == ["saved on server"])
        #expect(!editor.isDirty)
        #expect(!editor.canEdit)
        #expect(editor.error == nil)
    }

    @Test func onlyCompleteUtf8SnapshotsRoundTrip() throws {
        let original = try contents("é\r\n", byteLength: 7)
        let replacement = original.replacingText("new\r\n")
        #expect(original.lossless)
        #expect(Array(replacement.encodedText.utf8) == [239, 187, 191, 110, 101, 119, 13, 10])
        #expect(try !contents("é").matches(contents("e\u{301}")))
        #expect(try !contents("partial", byteLength: 50, truncated: true).lossless)
        #expect(try !contents("\u{fffd}\u{301}").lossless)
    }

    private func contents(_ text: String, byteLength: Int? = nil, truncated: Bool = false) throws -> WorkspaceFileContents {
        try .init(.object(["contents": .string(text), "byteLength": .int(byteLength ?? text.utf8.count), "truncated": .bool(truncated)]))
    }
}
