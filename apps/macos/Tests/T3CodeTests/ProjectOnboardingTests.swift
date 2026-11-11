import Testing
@testable import T3Code

struct ProjectOnboardingTests {
    @Test func hostPathsUseTheEnvironmentsSeparatorsAndRelativeRoot() throws {
        #expect(try ProjectHostPath.resolve("../Next Project/", cwd: "/srv/project", platform: "linux") == "/srv/Next Project")
        #expect(try ProjectHostPath.resolve("'/srv/Owner'\\''s Folder'", cwd: nil, platform: "linux") == "/srv/Owner's Folder")
        #expect(try ProjectHostPath.resolve(#"..\Other\"#, cwd: #"C:\Work\Repo"#, platform: "windows") == #"C:\Work\Other"#)
        #expect(ProjectHostPath.parent(of: #"\\server\share\repo"#, platform: "windows") == #"\\server\share"#)
        #expect(ProjectHostPath.parent(of: #"\\server\share"#, platform: "windows") == nil)
        #expect(ProjectHostPath.matches(#"C:\Work\Repo\"#, "c:/work/repo", platform: "windows"))
        #expect(!ProjectHostPath.matches("/srv/Repo", "/srv/repo", platform: "linux"))
        #expect(throws: ClientError.self) { try ProjectHostPath.resolve("../repo", cwd: nil, platform: "linux") }
        #expect(throws: ClientError.self) { try ProjectHostPath.resolve(#"C:\repo"#, cwd: nil, platform: "linux") }
    }

    @Test func cloneSuggestionsHandleRepositoryShorthandAndSafeGhqPaths() {
        #expect(CloneAddress.normalized("owner/repo") == "https://github.com/owner/repo.git")
        #expect(CloneAddress.normalized("/srv/git/repo.git") == "/srv/git/repo.git")
        #expect(CloneAddress.directory("git@github.com:owner/repo.git", ghq: true) == "github.com/owner/repo")
        #expect(CloneAddress.directory("ssh://git@gitlab.com:2222/team/sub/repo.git", ghq: true) == "gitlab.com/team/sub/repo")
        #expect(CloneAddress.directory("https://github.com/owner/%2E%2E/repo.git", ghq: true) == "repo")
        #expect(CloneAddress.directory("https://github.com/owner/%2Fescape.git", ghq: true) == nil)
        #expect(CloneAddress.directory("file:///srv/git/repo.git", ghq: true) == "repo")
    }

    @Test func cloneSnapshotsReconcileStartingRetryAndReconnection() {
        func frame(_ phase: String, sequence: Int, stalled: Bool = false) -> Wire {
            .array([.object(["projectId": .string("repo"), "phase": .string(phase), "stage": .string("receiving"),
                            "percent": .int(42), "detail": .string("10 MiB/s"), "stalled": .bool(stalled),
                            "sequence": .int(sequence)])])
        }
        var clones = ProjectCloneList()
        clones.markStarting("repo")
        let initial = clones.apply(.array([]))
        #expect(!initial)
        #expect(clones.status("repo")?.phase == .starting)
        _ = clones.apply(frame("running", sequence: 20, stalled: true))
        #expect(clones.status("repo")?.progressText == "Receiving objects · 42% · Stalled")
        #expect(clones.status("repo")?.blocksCheckout == true)
        _ = clones.apply(frame("failed", sequence: 21))
        let stale = clones.apply(frame("running", sequence: 20))
        #expect(!stale)
        #expect(clones.status("repo")?.canRetry == true)
        _ = clones.apply(frame("running", sequence: 22))
        #expect(clones.status("repo")?.canRetry == false)
        _ = clones.apply(frame("done", sequence: 2), reconnecting: true)
        #expect(clones.status("repo")?.blocksCheckout == false)
        _ = clones.apply(.array([]))
        #expect(clones.status("repo") == nil)
    }
}
