import Foundation
import Testing
@testable import T3Code

struct LocalServerTests {
    @Test func bundledCheckoutStartsThroughNodeWithItsCompatibilityModule() throws {
        let cli = URL(fileURLWithPath: "/tools/t3")
        let node = URL(fileURLWithPath: "/app/Contents/Helpers/node")
        let source = URL(fileURLWithPath: "/checkout/apps/server/src/bin.ts")
        let module = URL(fileURLWithPath: "/app/Contents/Resources/server-compatibility.mjs")
        let runtime = try LocalServerRuntime.resolve(cliCandidates: [cli], sourceEntry: source, nodeCandidates: [node],
                                                    compatibilityModule: module, isExecutable: { _ in true }, exists: { _ in true })
        #expect(runtime.executable == node)
        #expect(runtime.arguments == ["--import", module.path, source.path])
    }

    @Test func installedCLIAndExplicitExecutablesKeepTheirArguments() throws {
        let explicit = URL(fileURLWithPath: "/tools/custom-t3")
        let cli = URL(fileURLWithPath: "/tools/t3")
        let node = URL(fileURLWithPath: "/tools/node")
        let source = URL(fileURLWithPath: "/checkout/apps/server/src/bin.ts")
        let runtime = try LocalServerRuntime.resolve(executableOverride: explicit, cliCandidates: [cli], sourceEntry: source, nodeCandidates: [node],
                                                    isExecutable: { _ in true }, exists: { _ in true })
        #expect(runtime.executable == explicit)
        #expect(runtime.arguments.isEmpty)
        let clientOnly = try LocalServerRuntime.resolve(cliCandidates: [cli], sourceEntry: nil, nodeCandidates: [node],
                                                       isExecutable: { _ in true })
        #expect(clientOnly.executable == cli)
        #expect(clientOnly.arguments.isEmpty)
    }

    @Test func desktopCLIsAreFoundAfterExistingSearchPaths() {
        let home = URL(fileURLWithPath: "/Users/test")
        let applications = URL(fileURLWithPath: "/Applications")
        let codex = applications.appendingPathComponent("Codex.app/Contents/Resources")
        let chatGPT = applications.appendingPathComponent("ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS")
        let paths = LocalServerRuntime.searchPaths(environmentPath: "/custom/bin:/usr/bin:/custom/bin", home: home,
                                                   applicationDirectories: [applications], isExecutable: {
            $0 == codex.appendingPathComponent("codex") || $0 == chatGPT.appendingPathComponent("codex")
        })
        #expect(paths.prefix(2) == ["/custom/bin", "/usr/bin"])
        #expect(paths.filter { $0 == "/custom/bin" }.count == 1)
        #expect(paths.suffix(2) == [codex.path, chatGPT.path])
        #expect(!LocalServerRuntime.searchPaths(environmentPath: nil, home: home,
                                               applicationDirectories: [applications], isExecutable: { _ in false })
            .contains(chatGPT.path))
    }
}
