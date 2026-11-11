import Testing
@testable import T3Code

struct ProjectActionTests {
    @Test func importedActionsKeepCommandsAndSetupPreferences() throws {
        let file = try #require(ProjectFileConfiguration(.object(["contents": .string(#"""
        {
          "defaultThreadEnvMode": "worktree",
          "scripts": [
            {
              "name": " Start preview ",
              "command": " printf 'https://localhost:5173/*preview*/' ",
              "icon": "build",
              "runOnWorktreeCreate": true,
              "async": false,
              "runOnSettle": true,
              "stopOnSettle": true,
              "previewUrl": "http://localhost:5173",
              "autoOpenPreview": true,
            },
          ],
        }
        """#)])))
        let draft = try #require(file.actions.first)
        let saved = try draft.encode(id: "start-preview")
        #expect(file.checkout == .worktree)
        #expect(saved["name"].string == "Start preview")
        #expect(saved["command"].string == "printf 'https://localhost:5173/*preview*/'")
        #expect(saved["async"].bool == false)
        #expect(saved["runOnSettle"].bool == true)
        #expect(saved["stopOnSettle"].bool == true)
        #expect(saved["autoOpenPreview"].bool == true)
    }

    @Test func editsRetainOtherActionsAndRejectStaleCopies() throws {
        let original: Wire = .object([
            "id": .string("test"), "name": .string("Tests"), "command": .string("npm test"),
            "icon": .string("test"), "runOnWorktreeCreate": .bool(false), "futureField": .string("keep"),
        ])
        let action = try #require(ProjectAction(original))
        let another: Wire = .object(["id": .string("another"), "name": .string("Other"), "command": .string("true")])
        var draft = action.draft
        draft.command = "bun test"
        let change = ProjectActionChange.save(draft, id: action.id, replacing: action)
        let edited = try #require(try change.applying(to: [another, original]))
        #expect(edited.array.first == another)
        #expect(edited.array.last?["futureField"].string == "keep")
        #expect(edited.array.last?["command"].string == "bun test")
        #expect(throws: ClientError.self) { try change.applying(to: edited.array) }
        #expect(try ProjectActionChange.remove(action).applying(to: [another]) == .array([another]))
    }

    @Test func retryingAnAddDoesNotCreateAnotherAction() throws {
        var draft = ProjectActionDraft()
        draft.name = "Build"
        draft.command = "npm run build"
        let id = ProjectActionChange.newID()
        #expect(id.count == 24)
        let add = ProjectActionChange.save(draft, id: id, replacing: nil)
        let saved = try #require(try add.applying(to: []))
        #expect(try add.applying(to: saved.array) == saved)
        #expect(try ProjectActionChange.inherit.applying(to: saved.array) == nil)
    }
}
