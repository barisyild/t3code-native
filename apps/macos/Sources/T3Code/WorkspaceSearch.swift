import Foundation

extension Workspace {
    var messageSearchScope: MessageSearchScope? {
        guard can("orchestration:read"), let connectionID, let environment else { return nil }
        return .init(connection: connectionID, environmentID: environment.id)
    }

    var fileSearchScope: FileSearchScope? {
        guard can("filesystem:read"), let connectionID, let workspaceFileContext else { return nil }
        return .init(connection: connectionID, context: workspaceFileContext)
    }

    func searchMessages(_ query: String, scope: MessageSearchScope) async throws -> [MessageSearchResult] {
        guard messageSearchScope == scope else { throw ClientError.disconnected }
        let query = SearchText.messageQuery(query)
        guard !SearchText.messageWords(query).isEmpty else { return [] }
        let result = try await request("orchestration.searchThreads", ["query": .string(query), "limit": .int(30)])
        try Task.checkCancellation()
        guard messageSearchScope == scope else { throw ClientError.disconnected }
        guard case .array(let matches) = result["matches"] else { throw ClientError.invalidResponse }
        var seen = Set<String>()
        let hits = matches.compactMap(ThreadMessageHit.init).filter { seen.insert($0.threadID).inserted }
        let unknown = hits.filter { data.threads[$0.threadID] == nil && data.archived[$0.threadID] == nil }.map { Wire.string($0.threadID) }
        var titles: Wire = .null
        if !unknown.isEmpty {
            titles = try await request("orchestration.getThreadTitles", ["threadIds": .array(unknown)])
            try Task.checkCancellation()
            guard messageSearchScope == scope else { throw ClientError.disconnected }
        }
        return hits.compactMap { hit in
            if data.archived[hit.threadID] != nil { return nil }
            if let thread = data.threads[hit.threadID], !data.isListed(thread) { return nil }
            guard let title = data.threads[hit.threadID]?.title ?? titles[hit.threadID].string else { return nil }
            return .init(hit: hit, title: title, projectTitle: data.projects[hit.projectID]?.name)
        }
    }

    func searchFiles(_ query: String, contents options: FileContentSearchOptions?, scope: FileSearchScope) async throws -> WorkspaceSearchResults {
        guard fileSearchScope == scope else { throw ClientError.disconnected }
        let query = SearchText.limited(query, to: 256)
        var input: Payload = ["cwd": .string(scope.context.root), "limit": .int(40)]
        let method: String
        let key: String
        if let options {
            guard !query.isEmpty else { return .init(hits: [], truncated: false, warning: nil) }
            method = "projects.searchContents"
            key = "matches"
            input["query"] = .string(query)
            input["caseSensitive"] = .bool(options.caseSensitive)
            input["wholeWord"] = .bool(options.wholeWord)
            input["useRegex"] = .bool(options.regex)
        } else {
            method = "projects.searchEntries"
            key = "entries"
            input["query"] = .string(query.trimmingCharacters(in: .whitespacesAndNewlines))
            input["kind"] = .string("file")
        }
        let result = try await request(method, input)
        try Task.checkCancellation()
        guard fileSearchScope == scope else { throw ClientError.disconnected }
        guard case .array(let rows) = result[key] else { throw ClientError.invalidResponse }
        return .init(hits: rows.compactMap { FileSearchHit($0, root: scope.context.root, content: options != nil) },
                     truncated: result["truncated"].bool == true, warning: result["regexFallbackError"].string)
    }
}
