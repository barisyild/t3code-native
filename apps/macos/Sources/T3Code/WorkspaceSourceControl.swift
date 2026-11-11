import Foundation

struct RepositoryTarget: Equatable {
    let connection: UUID
    let selection: Workspace.Selection
    let project: Project
    let path: String
    let worktreePath: String?

    var threadID: String? {
        if case .thread(let id) = selection { return id }
        return nil
    }

    var input: Payload { ["cwd": .string(path)] }
}

extension Workspace {
    var repository: RepositoryTarget? {
        guard can("orchestration:read"), let connectionID, let selection,
              let project = selectedProject, !isScratch(project), let workspacePath else { return nil }
        return RepositoryTarget(connection: connectionID, selection: selection, project: project,
                                path: workspacePath, worktreePath: selectedThread?.worktreePath ?? draftCheckout.path)
    }

    func isCurrent(_ target: RepositoryTarget) -> Bool {
        connectionID == target.connection && selection == target.selection &&
            selectedProject?.id == target.project.id && selectedProject?.root == target.project.root &&
            workspacePath == target.path
    }

    func canChangeRepository(_ target: RepositoryTarget) -> Bool {
        isCurrent(target) && can("source-control:write") && selectedProject?.archived == false &&
            selectedThread?.archived != true && selectedThread?.isWorking != true &&
            !sending.contains(target.selection)
    }

    func requireRepositoryWrite(_ target: RepositoryTarget) throws {
        guard canChangeRepository(target) else {
            throw ClientError.message("The checkout or permissions changed. Finish any active run and reopen Source Control.")
        }
    }

    func changeCheckout(_ checkout: WorkspaceCheckout, in target: RepositoryTarget) async throws {
        guard isCurrent(target), can("orchestration:operate") else { throw ClientError.disconnected }
        guard let threadID = target.threadID else {
            setDraftCheckout(checkout)
            return
        }
        guard let thread = selectedThread, !thread.isWorking, !thread.archived else {
            throw ClientError.message("Finish the active run before changing its checkout.")
        }
        guard thread.branch != checkout.branch || thread.worktreePath != checkout.path else { return }
        try await dispatch("thread.metadata.update", threadId: threadID, [
            "branch": checkout.branch.map(Wire.string) ?? .null,
            "worktreePath": checkout.path.map(Wire.string) ?? .null,
            "expectedWorktreePath": thread.worktreePath.map(Wire.string) ?? .null,
            "expectedBranch": thread.branch.map(Wire.string) ?? .null,
        ])
    }

    func checkout(_ ref: RepositoryRef, in target: RepositoryTarget) async throws {
        try requireRepositoryWrite(target)
        guard can("orchestration:operate") else { throw ClientError.disconnected }
        let projectCheckoutRoot: String
        if ref.worktreePath != nil {
            let status = try await request("vcs.refreshStatus", ["cwd": .string(target.project.root), "localOnly": .bool(true)])
            projectCheckoutRoot = status["workingTree"]["rootPath"].string ?? target.project.root
            try requireRepositoryWrite(target)
        } else { projectCheckoutRoot = target.project.root }
        let destination = ref.checkout(projectRoot: projectCheckoutRoot, activeWorktree: target.worktreePath)
        if ref.worktreePath != nil {
            try await changeCheckout(destination, in: target)
            return
        }
        let result = try await request("vcs.switchRef", [
            "cwd": .string(destination.path ?? target.project.root), "refName": .string(ref.name),
        ])
        let branch = result["refName"].string ?? ref.name
        try await changeCheckout(destination.path.map { .worktree(path: $0, branch: branch) } ?? .root(branch: branch),
                                 in: target)
    }

    func createBranch(_ name: String, in target: RepositoryTarget) async throws {
        try requireRepositoryWrite(target)
        guard can("orchestration:operate") else { throw ClientError.disconnected }
        let result = try await request("vcs.createRef", target.input.merging([
            "refName": .string(name), "switchRef": .bool(true),
        ], uniquingKeysWith: { _, right in right }))
        let branch = try result.requireString("refName")
        try await changeCheckout(target.worktreePath.map { .worktree(path: $0, branch: branch) } ?? .root(branch: branch),
                                 in: target)
    }
}
