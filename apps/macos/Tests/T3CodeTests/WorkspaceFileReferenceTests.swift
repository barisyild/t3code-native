import Foundation
import Testing
@testable import T3Code

struct WorkspaceFileReferenceTests {
    @Test func markdownPositionsAndPercentEscapesSurviveOpening() throws {
        let root = "/work/project"
        let authored = try #require(URL(string: "file:///work/project/src/Code%20%2520.swift#L12C3"))
        let reference = try #require(WorkspaceFileReference(markdown: authored, root: root))
        let position = try #require(WorkspaceFilePosition(line: 12, column: 3))
        #expect(reference == .file(.workspace("src/Code %20.swift"), position))
        let link = try #require(reference.link)
        #expect(WorkspaceFileReference(internalLink: link) == reference)

        let suffix = try #require(URL(string: "File.swift:12:3"))
        #expect(WorkspaceFileReference(markdown: suffix, root: root) == .file(.workspace("File.swift"), position))
    }

    @Test func filePathsKeepTheSelectedCheckoutAndHostScopes() throws {
        let root = "/work/project"
        #expect(WorkspaceFilePath.resolve("./src/../README.md", in: root) == .workspace("README.md"))
        #expect(WorkspaceFilePath.resolve("/work/project-other/readme.md", in: root) == .host("/work/project-other/readme.md"))
        #expect(WorkspaceFilePath.resolve("../outside.txt", in: root) == nil)
        #expect(WorkspaceFilePath.resolve("/work/project/../outside.txt", in: root) == nil)
        #expect(WorkspaceFilePath.resolve("~/readme.md", in: root) == .host("~/readme.md"))
        let folderNamedHome = try #require(WorkspaceFilePath.resolve("./~/readme.md", in: root))
        #expect(folderNamedHome == .workspace("~/readme.md"))
        #expect(folderNamedHome.requestPath == "./~/readme.md")

        let escaped = "docs/Notes%20:12.txt"
        #expect(WorkspaceFileReference(changedPath: escaped, root: root) == .file(.workspace(escaped), nil))
        let folder = try #require(URL(string: "docs/"))
        #expect(WorkspaceFileReference(markdown: folder, root: root) == .directory("docs"))
    }

    @Test func windowsLinksUseTheEnvironmentDriveAndShare() throws {
        let root = #"C:\Work\Repo"#
        let position = try #require(WorkspaceFilePosition(line: 4, column: 9))
        #expect(WorkspaceFileReference(inlineCode: #"src\File.swift:4:9"#, root: root) == .file(.workspace("src/File.swift"), position))
        let absolute = try #require(URL(string: "file:///c:/work/repo/src/File.swift#L4C9"))
        #expect(WorkspaceFileReference(markdown: absolute, root: root) == .file(.workspace("src/File.swift"), position))

        let share = #"\\build\files\repo"#
        let sameShare = try #require(URL(string: "file://BUILD/files/repo/README.md"))
        #expect(WorkspaceFileReference(markdown: sameShare, root: share) == .file(.workspace("README.md"), nil))
        let otherShare = try #require(URL(string: "file://other/files/repo/README.md"))
        #expect(WorkspaceFileReference(markdown: otherShare, root: share) == nil)
    }

    @Test func inlineCodeLeavesVersionsDomainsAndShortenedPathsAlone() throws {
        let root = "/work/project"
        for text in ["README.md", "node/v1.2", "example.com/file.swift", "src/…/main.swift", "src/.../main.swift", "https://example.com/x.swift"] {
            #expect(WorkspaceFileReference(inlineCode: text, root: root) == nil)
        }
        let reference = WorkspaceFileReference(inlineCode: "src/File.swift", root: root)
        #expect(reference == .file(.workspace("src/File.swift"), nil))
        let injected = try #require(URL(string: "t3code-appkit-file://open?file=../outside.txt"))
        #expect(WorkspaceFileReference(markdown: injected, root: root) == nil)
    }

    @Test func textLocationsRespectCRLFAndComposedCharacters() throws {
        let text = "First\r\nhé 🚀\nLast\n"
        let emoji = try #require(WorkspaceFilePosition(line: 2, column: 5))
        #expect(emoji.selection(in: text) == NSRange(location: 10, length: 2))
        let line = try #require(WorkspaceFilePosition(line: 3, column: nil))
        #expect(line.selection(in: text) == NSRange(location: 13, length: 4))
        let trailing = try #require(WorkspaceFilePosition(line: 4, column: nil))
        #expect(trailing.selection(in: text) == NSRange(location: 18, length: 0))
        #expect(trailing.selection(in: "First\nSecond\nThird") == nil)
    }
}
