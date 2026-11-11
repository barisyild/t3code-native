import Testing
@testable import T3Code

struct SourceControlTests {
    @Test func worktreeRefPreservesTheProjectSubdirectoryAndAttachesSiblingCheckouts() throws {
        let root = "/work/app"
        let sibling = "/work/application-review"
        let projectRef = try #require(RepositoryRef(.object(["name": .string("main"), "worktreePath": .string(root)])))
        let reviewRef = try #require(RepositoryRef(.object(["name": .string("review"), "worktreePath": .string(sibling)])))
        #expect(projectRef.checkout(projectRoot: root + "/frontend", activeWorktree: sibling) == .root(branch: "main"))
        let reused = reviewRef.checkout(projectRoot: root + "/frontend", activeWorktree: nil)
        #expect(reused.strategy == .object([
            "type": .string("existing_worktree"), "worktreePath": .string(sibling), "branch": .string("review"),
        ]))
    }

    @Test func branchChangeDiscardsThePreviousBranchesRemoteActions() {
        var local: Payload = ["isRepo": .bool(true), "refName": .string("review"), "hasPrimaryRemote": .bool(true)]
        let remote: Wire = .object(["hasUpstream": .bool(true), "aheadCount": .int(3), "pr": .null])
        var status = RepositoryStatus()
        status.apply(.object(["_tag": .string("snapshot"), "local": .object(local), "remote": remote]))
        #expect(RepositoryAction.push.isAvailable(status: status, hasSelectedFiles: true))
        #expect(!RepositoryAction.createRequest.isAvailable(status: status, hasSelectedFiles: true))
        local["sourceControlProvider"] = .object(["kind": .string("github")])
        status.apply(.object(["_tag": .string("localUpdated"), "local": .object(local)]))
        #expect(RepositoryAction.createRequest.isAvailable(status: status, hasSelectedFiles: true))
        status.apply(.object(["_tag": .string("remoteUpdated"), "remote": .object([
            "hasUpstream": .bool(true), "aheadCount": .int(3), "pr": .object(["number": .int(12), "state": .string("open")]),
        ])]))
        status.apply(.object(["_tag": .string("localUpdated"), "local": .object([
            "isRepo": .bool(true), "refName": .string("main"), "hasPrimaryRemote": .bool(true),
            "hasWorkingTreeChanges": .bool(true),
        ])]))
        #expect(!RepositoryAction.push.isAvailable(status: status, hasSelectedFiles: true))
        #expect(status.pullRequest == .null)
        #expect(RepositoryAction.commit.isAvailable(status: status, hasSelectedFiles: true))
    }

    @Test(arguments: ["#42", "gh pr checkout 42", "glab mr checkout 42", "tea pulls checkout 42",
                      "origin pr checkout 42", "az repos pr checkout --id=42", "az repos pr checkout --id 42 --remote-name origin"])
    func requestReferencesResolveNumbersAndPastedCheckoutCommands(_ input: String) {
        #expect(RepositoryRequestReference(input)?.value == "42")
    }

    @Test func requestReferencesRejectCredentialURLsAndNonWebSchemes() {
        #expect(RepositoryRequestReference("https://example.test/team/project/pull/42") != nil)
        #expect(RepositoryRequestReference("https://user:secret@example.test/team/project/pull/42") == nil)
        #expect(RepositoryRequestReference("file:///tmp/pull/42") == nil)
    }
}
