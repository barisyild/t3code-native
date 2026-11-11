import Testing
@testable import T3Code

struct PullRequestTests {
    @Test func continuationKeepsTheNewerObservationAndDistinctRepositoryReferences() {
        let current = entry(number: 17, title: "Current review", observedAt: 12)
        let older = entry(number: 17, title: "Stale review", observedAt: 10)
        let other = entry(number: 17, title: "Other repository", repository: "ink/weave", observedAt: 12)
        var listing = PullRequestListing()
        listing.apply(.object(["entries": .array([current]), "nextCursors": .object(["loom": .string("page2")])]), append: false)
        listing.apply(.object(["entries": .array([older, other]), "nextCursors": .object([:])]), append: true)
        #expect(listing.items.map(\.title) == ["Current review", "Other repository"])
        #expect(listing.cursors.isEmpty)
    }

    @Test func unsupportedHostSearchAndInvolvementUseTheListedIdentity() {
        var listing = PullRequestListing()
        listing.apply(.object([
            "entries": .array([entry(number: 17, title: "Sidebar stays put", observedAt: 12),
                               entry(number: 19, title: "Keep tabs in order", author: "other", observedAt: 12, requested: true)]),
            "viewers": .object(["forgejo.example.test": .string("reviewer")]),
        ]), append: false)
        #expect(listing.visibleItems(query: "sidebar", involvement: "authored").map(\.reference.number) == [17])
        #expect(listing.visibleItems(query: "", involvement: "reviewing").map(\.reference.number) == [19])
    }

    @Test func diffSplitsRenamesAndDeletionsWithoutCountingHeaders() {
        let patch = #"""
        diff --git "a/docs/M\303\251mo.txt" "b/docs/Review notes.txt"
        similarity index 80%
        rename from "docs/M\303\251mo.txt"
        rename to docs/Review notes.txt
        --- "a/docs/M\303\251mo.txt"
        +++ b/docs/Review notes.txt
        @@ -1 +1 @@
        -Old text
        +++ begins with two plus signs
        diff --git a/obsolete.txt b/obsolete.txt
        deleted file mode 100644
        --- a/obsolete.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -Obsolete
        """#
        let files = PullRequestFile.page(.object(["patch": .string(patch)]))
        #expect(files.map(\.kind) == ["rename-changed", "deleted"])
        #expect(files.first?.oldPath == "docs/Mémo.txt")
        #expect(files.first?.path == "docs/Review notes.txt")
        #expect(files.map(\.additions) == [1, 0])
        #expect(files.map(\.deletions) == [1, 1])
        #expect(files.last?.path == "obsolete.txt")
    }

    @Test func omittedDiffStatsKeepTheFileVisibleWithoutInventingAPatch() {
        let result: Wire = .object(["patch": .string(""), "omittedFileStats": .array([
            .object(["path": .string("data/large.json"), "additions": .int(70), "deletions": .int(20)]),
        ])])
        let file = PullRequestFile.page(result).first
        #expect(file?.path == "data/large.json")
        #expect(file?.patch == nil)
        #expect(file?.additions == 70)
    }

    private func entry(number: Int, title: String, repository: String = "ink/loom", author: String = "reviewer",
                       observedAt: Double, requested: Bool = false) -> Wire {
        .object([
            "projectId": .string("project"), "host": .string("forgejo.example.test"), "repository": .string(repository),
            "number": .int(number), "title": .string(title), "author": .object(["login": .string(author)]),
            "viewerReviewRequested": .bool(requested), "observedAt": .double(observedAt),
            "updatedAt": .string("2026-11-10T15:00:00Z"),
        ])
    }
}
