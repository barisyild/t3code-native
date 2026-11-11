import Foundation

struct ProjectActionTarget: Equatable, Sendable {
    let project: ProjectTarget
    let threadID: String
    let projectRoot: String
    let worktreePath: String?

    var cwd: String { worktreePath ?? projectRoot }
}

struct ProjectActionTerminal: Sendable {
    let target: ProjectActionTarget
    let id: String
    let title: String
}

extension Workspace {
    var projectActionTarget: ProjectActionTarget? {
        guard can("terminal:operate"), let thread = selectedThread, let project = selectedProject,
              let target = projectTarget(project.id) else { return nil }
        return .init(project: target, threadID: thread.id, projectRoot: project.root, worktreePath: thread.worktreePath)
    }

    func runProjectAction(_ action: ProjectAction, target: ProjectActionTarget) async throws -> ProjectActionTerminal {
        guard canRunProjectAction(action, in: target) else {
            throw ClientError.message("The action or its checkout changed. Reopen the action menu.")
        }
        let input = " \(action.draft.command)\r"
        guard input.utf16.count <= 65_536 else { throw ClientError.message("This action exceeds the terminal input limit.") }
        let terminalID = "action-" + UUID().uuidString.lowercased()
        let session: Payload = ["threadId": .string(target.threadID), "terminalId": .string(terminalID)]
        var env: Payload = ["T3CODE_PROJECT_ROOT": .string(target.projectRoot)]
        if let worktreePath = target.worktreePath { env["T3CODE_WORKTREE_PATH"] = .string(worktreePath) }
        let options: Payload = [
            "cwd": .string(target.cwd), "worktreePath": target.worktreePath.map(Wire.string) ?? .null,
            "cols": .int(80), "rows": .int(24), "env": .object(env), "stopOnSettle": .bool(action.draft.stopOnSettle),
        ]
        let opened = try await request("terminal.open", session.merging(options) { _, value in value })
        guard !Task.isCancelled, canRunProjectAction(action, in: target) else {
            if connectionID == target.project.connection, can("terminal:operate") {
                _ = try? await request("terminal.close", session)
            }
            throw ClientError.disconnected
        }
        guard opened["status"].string == "running" else { throw ClientError.message("The action terminal could not start.") }
        var write = session
        write["data"] = .string(input)
        _ = try await request("terminal.write", write)
        return .init(target: target, id: terminalID, title: action.draft.name)
    }

    private func canRunProjectAction(_ action: ProjectAction, in target: ProjectActionTarget) -> Bool {
        guard can("terminal:operate"), projectTarget(target.project.id) == target.project,
              let project = data.projects[target.project.id], project.root == target.projectRoot,
              let thread = data.threads[target.threadID] ?? data.archived[target.threadID], thread.projectId == project.id,
              thread.worktreePath == target.worktreePath else { return false }
        return projectActions(project).contains(action)
    }
}
