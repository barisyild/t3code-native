import Darwin
import Foundation

struct LocalServerRuntime: Equatable {
    let executable: URL
    let arguments: [String]

    static func searchPaths(environmentPath: String?, home: URL, applicationDirectories: [URL],
                            isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }) -> [String] {
        let existing = environmentPath?.split(separator: ":").map(String.init) ?? []
        let standard = [home.appendingPathComponent(".local/bin").path, home.appendingPathComponent(".bun/bin").path,
                        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let bundled = applicationDirectories.flatMap { directory in
            ["Codex.app/Contents/Resources", "Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS",
             "ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS"].map(directory.appendingPathComponent)
        }.filter { isExecutable($0.appendingPathComponent("codex")) }.map(\.path)
        var seen = Set<String>()
        return (existing + standard + bundled).filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    static func resolve(executableOverride: URL? = nil, cliCandidates: [URL], sourceEntry: URL?, nodeCandidates: [URL],
                        compatibilityModule: URL? = nil,
                        isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) },
                        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) throws -> Self {
        if let executableOverride, isExecutable(executableOverride) {
            return Self(executable: executableOverride, arguments: [])
        }
        if let sourceEntry, exists(sourceEntry), let node = nodeCandidates.first(where: isExecutable) {
            var arguments: [String] = []
            if let compatibilityModule, exists(compatibilityModule) { arguments += ["--import", compatibilityModule.path] }
            arguments.append(sourceEntry.path)
            return Self(executable: node, arguments: arguments)
        }
        if let cli = cliCandidates.first(where: isExecutable) {
            return Self(executable: cli, arguments: [])
        }
        throw ClientError.message("This app needs a local T3 Code server. Build it from the T3 Code checkout with Node.js, or pair a running environment.")
    }
}

@MainActor
final class LocalServer {
    private let base: URL
    private let executableOverride: URL?
    private var process: Process?
    private var pairing: PairingTarget?
    private(set) var isStarting = false

    init(base: URL, executable: URL? = nil) {
        self.base = base
        executableOverride = executable
    }

    func start() async throws -> PairingTarget {
        if process?.isRunning == true, let pairing { return pairing }
        guard !isStarting else { throw ClientError.message("The local server is already starting.") }
        isStarting = true
        defer { isStarting = false }

        let runtime = try findRuntime()
        let manager = FileManager.default
        try manager.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let port = try Self.loopbackPort()
        let credential = UUID().uuidString + UUID().uuidString
        let target = try PairingTarget(address: "http://127.0.0.1:\(port)", code: credential)
        let child = Process()
        child.executableURL = runtime.executable
        child.currentDirectoryURL = base
        child.arguments = runtime.arguments + ["--bootstrap-fd", "0", "--mode", "desktop", "--host", "127.0.0.1", "--port", "\(port)",
                                               "--base-dir", base.path, "--no-browser"]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "VITE_DEV_SERVER_URL")
        environment.removeValue(forKey: "T3CODE_AUTO_BOOTSTRAP_PROJECT_FROM_CWD")
        environment["T3CODE_TAILSCALE_SERVE"] = "false"
        environment["T3CODE_LAN"] = "false"
        environment["PATH"] = ([runtime.executable.deletingLastPathComponent().path] + Self.searchPaths()).joined(separator: ":")
        child.environment = environment

        let bootstrap = Pipe()
        child.standardInput = bootstrap.fileHandleForReading
        let log = base.appendingPathComponent("appkit-server.log")
        if !manager.fileExists(atPath: log.path) {
            manager.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }
        try logHandle.truncate(atOffset: 0)
        child.standardOutput = logHandle
        child.standardError = logHandle

        let envelope: Payload = [
            "mode": .string("desktop"), "noBrowser": .bool(true), "port": .int(port), "host": .string("127.0.0.1"),
            "desktopBootstrapToken": .string(credential), "tailscaleServeEnabled": .bool(false), "tailscaleServePort": .int(443),
        ]
        var payload = try JSONEncoder().encode(envelope)
        payload.append(10)
        // Fill the pipe before spawn so the short bootstrap read never waits on the UI.
        try bootstrap.fileHandleForWriting.write(contentsOf: payload)
        try bootstrap.fileHandleForWriting.close()
        try child.run()
        try? bootstrap.fileHandleForReading.close()
        process = child

        let state = base.appendingPathComponent("userdata/server-runtime.json")
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(runtime.arguments.isEmpty ? 30 : 120))
        do {
            while clock.now < deadline {
                try Task.checkCancellation()
                guard child.isRunning else { throw ClientError.message("The T3 server exited. See \(log.path).") }
                if let data = try? Data(contentsOf: state), let record = try? JSONDecoder().decode(Wire.self, from: data),
                   record["pid"].int == Int(child.processIdentifier), record["port"].int == port {
                    pairing = target
                    return target
                }
                try await clock.sleep(for: .milliseconds(150))
            }
            throw ClientError.message("The T3 server took too long to start. See \(log.path).")
        } catch {
            if process === child { stop() }
            throw error
        }
    }

    func stop() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        pairing = nil
    }

    private func findRuntime() throws -> LocalServerRuntime {
        let manager = FileManager.default
        let candidates = [Bundle.main.url(forResource: "t3", withExtension: nil),
                          manager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/t3")].compactMap { $0 }
        let paths = Self.searchPaths()
        let all = candidates + paths.map { URL(fileURLWithPath: $0).appendingPathComponent("t3") }
        let source = (Bundle.main.object(forInfoDictionaryKey: "T3CODE_SOURCE_ROOT") as? String).map {
            URL(fileURLWithPath: $0).appendingPathComponent("apps/server/src/bin.ts")
        }
        let bundledNode = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/node")
        return try LocalServerRuntime.resolve(executableOverride: executableOverride, cliCandidates: all, sourceEntry: source,
                                              nodeCandidates: [bundledNode] + paths.map { URL(fileURLWithPath: $0).appendingPathComponent("node") },
                                              compatibilityModule: Bundle.main.url(forResource: "server-compatibility", withExtension: "mjs"))
    }

    private static func searchPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return LocalServerRuntime.searchPaths(environmentPath: ProcessInfo.processInfo.environment["PATH"], home: home,
                                              applicationDirectories: [home.appendingPathComponent("Applications"),
                                                                       URL(fileURLWithPath: "/Applications")])
    }

    private static func loopbackPort() throws -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw ClientError.message("Couldn’t reserve a loopback port.") }
        defer { Darwin.close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, length) }
        }
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        guard bound == 0, named == 0 else { throw ClientError.message("Couldn’t reserve a loopback port.") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
