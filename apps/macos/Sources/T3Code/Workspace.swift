import Foundation

@MainActor
final class Workspace {
    enum Connection: Equatable {
        case offline, connecting, ready, retrying, needsPairing
    }

    enum Selection: Hashable {
        case project(String)
        case thread(String)
    }

    enum ThreadShellChange {
        case snapshot
        case threads(Set<String>)
    }

    struct Change: OptionSet {
        let rawValue: Int
        static let connection = Self(rawValue: 1 << 0)
        static let sidebar = Self(rawValue: 1 << 1)
        static let selection = Self(rawValue: 1 << 2)
        static let timeline = Self(rawValue: 1 << 3)
        static let providers = Self(rawValue: 1 << 4)
        static let projects = Self(rawValue: 1 << 5)
        static let clones = Self(rawValue: 1 << 6)
        static let sideChat = Self(rawValue: 1 << 7)
        static let browserSettings = Self(rawValue: 1 << 8)
        static let voiceInput = Self(rawValue: 1 << 9)
        static let voiceSettings = Self(rawValue: 1 << 10)
        static let all: Self = [.connection, .sidebar, .selection, .timeline, .providers, .projects, .clones, .sideChat,
                                .browserSettings, .voiceInput, .voiceSettings]
    }

    struct SendIntent: Equatable {
        let destination: Selection
        let text: String
        let model: Wire
        let runtimeMode: String
        let interactionMode: String
        let checkout: WorkspaceCheckout?
        let preparedThreadID: String?
        var freshContext = false
        var attachments: [PickedAttachment] = []
        var deliveryIntent: String?
        var modelSwitch: ThreadQueue.ModelSwitchDelivery?
        var retainedAttachments: [Wire] = []
        var retainedContextRecords: [Wire] = []
    }

    struct QueueEditContent: Equatable {
        let text: String
        let retained: [Wire]?
        let files: [PickedAttachment]
        var terminalContextRecords: [Wire]? = nil
    }

    final class QueueEditAttempt {
        let content: QueueEditContent
        fileprivate let commandID = UUID().uuidString
        fileprivate var uploaded: [UUID: UploadedAttachment] = [:]

        init(content: QueueEditContent) { self.content = content }
    }

    struct QuestionResponseTarget {
        let environmentID: String
        let threadID: String
        let requestID: String
    }

    final class QuestionResponseAttempt {
        let content: QuestionResponseContent
        fileprivate let commandID = UUID().uuidString
        fileprivate var connection: UUID?
        fileprivate var uploaded: [UUID: UploadedAttachment] = [:]

        init(content: QuestionResponseContent) { self.content = content }
    }

    fileprivate struct UploadedAttachment {
        let reference: Wire
        let expiresAt: Int

        var isValid: Bool { expiresAt > Int(Date().timeIntervalSince1970 * 1_000) }
    }

    private struct DraftCheckout: Equatable {
        var checkout: WorkspaceCheckout = .root()
        var threadID: String?
    }

    private struct DraftFileCheckout {
        let scope: ProjectFileScope
        let id: UUID
        let task: Task<ProjectCheckoutMode?, Never>
        var mode: ProjectCheckoutMode?
    }

    private struct SendAttempt {
        let intent: SendIntent
        let commandId = UUID().uuidString
        let threadId: String
        let messageId = UUID().uuidString
        var uploaded: [UUID: UploadedAttachment] = [:]
        var checkout: WorkspaceCheckout?

        init(intent: SendIntent) {
            self.intent = intent
            threadId = intent.preparedThreadID ?? UUID().uuidString
        }
    }

    private let preferences: UserDefaults?
    let browserRecordingDirectory: URL
    let browserScreenshotDirectory: URL
    private let browserProfileReporter = BrowserProfileReporter()
    private var browserProfileClear: (profileID: String, connection: UUID)?
    private let relayClient: ManagedRelayClient?
    private var connectionTask: Task<Void, Never>?
    private var threadTask: Task<Void, Never>?
    private var sideChatTask: Task<Void, Never>?
    private var sideChatWaiters: [String: AsyncStream<Void>.Continuation] = [:]
    private var archiveTask: Task<Void, Never>?
    private var cloneTask: Task<Void, Never>?
    private var api: EnvironmentAPI?
    private var socket: RPCSocket?
    private var socketID = UUID()
    private var auth: Wire = .null
    private var generation = UUID()
    private var relatedLanding: RelatedThreadTarget?
    private var sendAttempts: [Selection: SendAttempt] = [:]
    private var activeSelection: Selection?
    private var draftCheckouts: [String: [String: DraftCheckout]] = [:]
    private var draftFileCheckout: DraftFileCheckout?

    private(set) var environments: [SavedEnvironment]
    private(set) var environment: SavedEnvironment?
    private(set) var currentServerID: String?
    private(set) var connection = Connection.offline
    private(set) var connectionError: String?
    private(set) var data = WorkspaceData()
    private(set) var detail = ThreadDetail()
    private(set) var detailError: String?
    private(set) var sideChat: SideChatReference?
    private(set) var sideChatDetail = ThreadDetail()
    private(set) var sideChatError: String?
    private(set) var providers: [Provider] = []
    private(set) var providerConfigurations: Payload?
    private var usageLimitSnapshots: [UsageLimitSource] = []
    private(set) var usageHubSettings = UsageHubSettings()
    var settingsSecretProviders: [SettingsSecretProvider] { usageHubSettings.secretProviders }
    private(set) var usageModelFilter: Wire = .null
    private(set) var projectPreferences = ProjectPreferences()
    private(set) var projectOnboardingSettings = ProjectOnboardingSettings()
    private(set) var deviceHostSettings = DeviceHostSettings()
    private(set) var browserPreferences: BrowserPreferences
    private(set) var supportsServerBrowser = false
    private(set) var supportsVoiceTranscription = false
    private(set) var supportsCloudVoiceTranscription = false
    private(set) var voiceCloudReferences: [VoiceCloudProvider: SettingsSecretReference] = [:]
    private(set) var voiceCleanupModel: Wire = .null
    private(set) var voiceTextGenerationModel: Wire = .null
    private var voicePreferencesByServer: [String: VoiceInputPreferences]
    private var speechWords: Wire = .null
    private var projectSpeechWords: Wire = .null
    private(set) lazy var voiceInput = makeVoiceInput()
    private(set) var environmentPlatform: String?
    private var cloneList = ProjectCloneList()
    private(set) var supportsProjectCloneTracking = false
    private(set) var supportsFreshContext = false
    private(set) var supportsQuestionAttachments = false
    private(set) var supportsSideChats = false
    private(set) var supportsThreadFamilies = false
    private(set) var supportsProjectOrganization = false
    private var commandCatalogs: [ComposerCommandScope: (catalog: ComposerCommandCatalog, expires: ContinuousClock.Instant)] = [:]
    private var modelSwitchWaiters: [String: (runID: String, connection: UUID, ended: AsyncStream<Void>.Continuation)] = [:]
    private var threadFindEnabled = false
    private var threadFindProgressive = false
    private(set) var sharingConfiguration = SharingConfiguration()
    private(set) var guestSharingEnabled: Bool?
    private var scratchWorkspaceRoot: String?
    private(set) var newProjectsRoot: String?
    private(set) var selection: Selection?
    private(set) var isShowingArchive = false
    private(set) var sending: Set<Selection> = []
    var onChange: ((Change) -> Void)?
    var onThreadShellChange: ((ThreadShellChange) -> Void)?
    var onError: ((String) -> Void)?

    var usageLimitSources: [UsageLimitSource] {
        guard let configurations = usageHubSettings.configurations else { return usageLimitSnapshots }
        return usageLimitSnapshots.filter { snapshot in
            snapshot.id.map { configurations[$0]?.enabled == true } ?? true
        }
    }

    var selectedThread: ThreadSummary? {
        guard case .thread(let id) = selection else { return nil }
        return data.threads[id] ?? data.archived[id]
    }

    func goalOwner(for thread: ThreadSummary?) -> ThreadGoal.Owner? {
        guard let thread, let owner = thread.activeProviderThreadID else { return nil }
        return presentedDetail(for: thread.id)?.goalOwners[owner]
    }

    func modelSwitchDelivery(for thread: ThreadSummary?) -> ThreadQueue.ModelSwitchDelivery? {
        guard let thread, !thread.archived, !thread.stopRequested, !thread.needsInput,
              let runID = thread.activeRunId else { return nil }
        return presentedDetail(for: thread.id)?.queue.modelSwitchDelivery(for: runID)
    }

    var supportsRewind: Bool {
        detail.queue.supportsRewind(providerThreadID: selectedThread?.activeProviderThreadID)
    }

    var selectedProject: Project? {
        switch selection {
        case .project(let id): data.projects[id]
        case .thread: selectedThread.flatMap { data.projects[$0.projectId] }
        case nil: nil
        }
    }

    func defaultModel(for project: Project?) -> Wire {
        project.map { projectPreferences.value(.model, for: $0) } ?? .null
    }

    var connectionID: UUID? { connection == .ready && socket != nil ? socketID : nil }

    func threadFindScope(for threadID: String?) -> ThreadFindScope? {
        guard threadFindEnabled, can("orchestration:read"), let threadID,
              presentedDetail(for: threadID)?.loaded == true, let connection = connectionID else { return nil }
        return .init(threadID: threadID, connection: connection, progressive: threadFindProgressive)
    }

    private var selectedDraftCheckout: DraftCheckout? {
        guard let environmentID = environment?.id, case .project(let id) = selection else { return nil }
        return draftCheckouts[environmentID]?[id]
    }

    var explicitDraftCheckout: WorkspaceCheckout? { selectedDraftCheckout?.checkout }
    var preparedDraftThreadID: String? { selectedDraftCheckout?.threadID }

    var draftCheckout: WorkspaceCheckout {
        if let explicitDraftCheckout { return explicitDraftCheckout }
        guard case .project(let id) = selection, let project = data.projects[id] else { return .root() }
        let mode = draftFileCheckout.flatMap { $0.scope.target.id == id && $0.scope.root == project.root ? $0.mode : nil }
        return defaultCheckout(for: project, fileMode: mode)
    }

    var workspacePath: String? {
        if let project = selectedProject, cloneStatus(project.id)?.blocksCheckout == true { return nil }
        return selectedThread?.worktreePath ?? draftCheckout.path ?? selectedProject?.root
    }

    var workspaceFileContext: WorkspaceFileContext? {
        guard let environment, let workspacePath else { return nil }
        return .init(environmentID: environment.id, root: workspacePath, threadID: selectedThread?.id)
    }

    func setDraftCheckout(_ checkout: WorkspaceCheckout, threadID: String? = nil) {
        guard let environmentID = environment?.id, case .project(let id) = selection else { return }
        let sameWorktree = checkout.path != nil && checkout.path == draftCheckout.path
        let next = DraftCheckout(checkout: checkout, threadID: threadID ?? (sameWorktree ? preparedDraftThreadID : nil))
        guard next != draftCheckouts[environmentID]?[id] else { return }
        draftCheckouts[environmentID, default: [:]][id] = next
        syncDraftFileCheckout()
        onChange?(.selection)
    }

    private func defaultCheckout(for project: Project, fileMode: ProjectCheckoutMode?) -> WorkspaceCheckout {
        guard !isScratch(project) else { return .root() }
        return projectPreferences.checkout(for: project, fileMode: fileMode, newProjectsRoot: newProjectsRoot,
                                           hasThreads: data.hasThreads(in: project.id))
    }

    private func syncDraftFileCheckout(refresh: Bool = false) {
        let scope: ProjectFileScope? = {
            guard case .project(let id) = selection, let project = data.projects[id], !project.archived, !isScratch(project),
                  cloneStatus(id)?.blocksCheckout != true,
                  explicitDraftCheckout == nil, projectPreferences.configuredCheckout(for: project) == nil else { return nil }
            return projectFileScope(id)
        }()
        guard refresh || scope != draftFileCheckout?.scope else { return }
        if let previous = draftFileCheckout, !sending.contains(.project(previous.scope.target.id)) { previous.task.cancel() }
        draftFileCheckout = nil
        guard let scope else { return }
        let id = UUID()
        let task = Task<ProjectCheckoutMode?, Never> { [weak self] in
            guard let self else { return nil }
            let mode = (try? await readProjectFile(scope))?.checkout
            guard !Task.isCancelled else { return nil }
            if draftFileCheckout?.id == id {
                draftFileCheckout?.mode = mode
                if mode != nil { onChange?(.selection) }
            }
            return mode
        }
        draftFileCheckout = .init(scope: scope, id: id, task: task)
    }

    func isScratch(_ project: Project) -> Bool { project.root == scratchWorkspaceRoot }

    init(persistent: Bool = true, relayClient: ManagedRelayClient? = nil) {
        preferences = persistent ? .standard : nil
        self.relayClient = relayClient
        voicePreferencesByServer = preferences?.data(forKey: VoiceInputPreferences.storageKey).flatMap {
            try? JSONDecoder().decode([String: VoiceInputPreferences].self, from: $0)
        } ?? [:]
        let mediaRoot: URL
        if persistent {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            mediaRoot = support.appendingPathComponent("T3 Code AppKit", isDirectory: true)
        } else {
            mediaRoot = FileManager.default.temporaryDirectory.appendingPathComponent("t3-browser-media-\(UUID())", isDirectory: true)
        }
        browserRecordingDirectory = mediaRoot.appendingPathComponent("Browser Recordings", isDirectory: true)
        browserScreenshotDirectory = mediaRoot.appendingPathComponent("Browser Screenshots", isDirectory: true)
        environments = preferences?.data(forKey: "environments").flatMap {
            try? JSONDecoder().decode([SavedEnvironment].self, from: $0)
        } ?? []
        let browserSettings = preferences?.data(forKey: BrowserPreferences.storageKey).flatMap {
            try? JSONDecoder().decode(Wire.self, from: $0)
        }
        browserPreferences = BrowserPreferences(browserSettings ?? .null)
    }

    private func makeVoiceInput() -> VoiceDictation {
        let voice = VoiceDictation()
        voice.onChange = { [weak self] in self?.onChange?(.voiceInput) }
        return voice
    }

    var voiceTarget: VoiceTarget? {
        guard supportsVoiceTranscription || supportsCloudVoiceTranscription, can("orchestration:operate"), let connection = connectionID,
              let environment, let serverID = currentServerID else { return nil }
        return .init(connection: connection, environmentID: environment.id, serverID: serverID)
    }

    var voicePreferences: VoiceInputPreferences {
        currentServerID.flatMap { voicePreferencesByServer[$0] } ?? VoiceInputPreferences()
    }

    func setVoicePreferences(_ next: VoiceInputPreferences, target: VoiceTarget) {
        guard voiceTarget == target else { return }
        let previous = voicePreferences
        var next = next
        if (previous.cloud != next.cloud && previous.grant == next.grant) || !supportsVoiceDestination(next.cloud) { next.grant = nil }
        guard next != previous else { return }
        voicePreferencesByServer[target.serverID] = next
        if let data = try? JSONEncoder().encode(voicePreferencesByServer) {
            preferences?.set(data, forKey: VoiceInputPreferences.storageKey)
        }
        voiceInput.invalidate(target: target, grant: next.grant, cleanupGrant: next.cleanupGrant)
        onChange?(.voiceSettings)
    }

    func supportsVoiceDestination(_ cloud: VoiceCloudDestination?) -> Bool {
        if let cloud { return supportsCloudVoiceTranscription && cloud.isValid }
        return supportsVoiceTranscription
    }

    func voiceAPI(_ target: VoiceTarget) throws -> EnvironmentAPI {
        guard voiceTarget == target, let api else { throw ClientError.disconnected }
        return api
    }

    func voiceVocabulary(for project: Project?, hints: [String] = []) -> [Wire] {
        let override = project.map { projectSpeechWords[$0.id]["speechProjectCustomWords"] } ?? .null
        let words = (override == .null ? speechWords : override).array
        let spellings = words.flatMap { [$0["term"].string].compactMap { $0 } + $0["aliases"].array.compactMap(\.string) }
        var known = Set(spellings.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        let extras: [Wire] = (hints + [project?.name].compactMap { $0 }).compactMap { hint in
            let term = hint.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !term.isEmpty, term.utf16.count <= 50,
                  known.insert(term.precomposedStringWithCanonicalMapping.lowercased()).inserted else { return nil }
            return .object(["term": .string(term), "aliases": .array([])])
        }
        return Array((extras + words).prefix(100))
    }

    func setVoiceCleanupModel(_ model: Wire, target: VoiceTarget) async throws {
        guard voiceTarget == target, can("settings:write") else { throw ClientError.disconnected }
        let previous = voiceCleanupModel
        let result = try await request("server.updateSettings", ["patch": .object(["speechPostProcessingModelSelection": model])])
        guard voiceTarget == target else { throw ClientError.disconnected }
        if voiceCleanupModel == previous, let current = result.object?["speechPostProcessingModelSelection"] {
            voiceCleanupModel = current
            onChange?(.voiceSettings)
        }
    }

    func updateBrowserPreferences(_ next: BrowserPreferences) {
        guard browserPreferences != next else { return }
        browserPreferences = next
        if let data = try? JSONEncoder().encode(next.storedValue) {
            preferences?.set(data, forKey: BrowserPreferences.storageKey)
        }
        reportBrowserProfiles()
        onChange?(.browserSettings)
    }

    var clearingBrowserProfileID: String? {
        guard let browserProfileClear, browserProfileClear.connection == connectionID else { return nil }
        return browserProfileClear.profileID
    }

    var canClearBrowserProfiles: Bool {
        supportsServerBrowser && connectionID != nil && can("preview:operate") && clearingBrowserProfileID == nil
    }

    func clearBrowserProfile(_ profileID: String, connection: UUID, removing: Bool = false) async throws {
        guard canClearBrowserProfiles, connectionID == connection,
              let profile = browserPreferences.profile(profileID), profile.kind == .persistent,
              !removing || !profile.builtIn else { throw ClientError.disconnected }
        browserProfileClear = (profileID, connection)
        onChange?(.browserSettings)
        defer {
            if browserProfileClear?.connection == connection {
                browserProfileClear = nil
                onChange?(.browserSettings)
            }
        }
        _ = try await request("preview.clearProfile", ["profileId": .string(profileID)])
        guard connectionID == connection else { throw ClientError.disconnected }
        if removing {
            var next = browserPreferences
            next.removeProfile(profileID)
            updateBrowserPreferences(next)
        }
    }

    private func reportBrowserProfiles() {
        guard supportsServerBrowser, can("preview:operate"), let socket else {
            browserProfileReporter.reset()
            return
        }
        browserProfileReporter.update(browserPreferences.report, on: socket)
    }

    func restoreConnection() {
        if let id = preferences?.string(forKey: "activeEnvironment"),
           let saved = environments.first(where: { $0.id == id }) {
            connect(to: saved)
        }
    }

    func pair(_ target: PairingTarget, persistent: Bool = true) {
        let name = target.label.flatMap { $0.isEmpty ? nil : $0 } ?? target.origin.host() ?? "Environment"
        start(SavedEnvironment(origin: target.origin, name: name), credential: target.credential,
              token: nil, persist: persistent && preferences != nil)
    }

    func connect(to environment: SavedEnvironment, opening target: RelatedThreadTarget? = nil) {
        do {
            let token = environment.relay == nil ? try EnvironmentKeychain.load(environment.origin) : nil
            start(environment, credential: nil, token: token, persist: preferences != nil, opening: target)
        } catch {
            onError?(error.localizedDescription)
        }
    }

    func disconnect() {
        stopConnection()
        environment = nil
        connection = .offline
        connectionError = nil
        preferences?.removeObject(forKey: "activeEnvironment")
        clearWorkspace()
        onChange?(.all)
    }

    func forget(_ saved: SavedEnvironment) throws {
        if let route = saved.relay, let relayClient { Task { await relayClient.forget(route) } }
        else if saved.relay == nil { try EnvironmentKeychain.remove(saved.origin) }
        environments.removeAll { $0.id == saved.id }
        draftCheckouts.removeValue(forKey: saved.id)
        storeEnvironments()
        if environment?.id == saved.id { disconnect() }
        else { onChange?(.connection) }
    }

    func removeRelayEnvironments(for accountID: String) {
        let removed = environments.filter { $0.relay?.accountID == accountID }
        for saved in removed { draftCheckouts.removeValue(forKey: saved.id) }
        environments.removeAll { $0.relay?.accountID == accountID }
        storeEnvironments()
        if environment?.relay?.accountID == accountID { disconnect() }
        else { onChange?(.connection) }
    }

    func shutdown() { stopConnection() }

    private func start(_ saved: SavedEnvironment, credential: String?, token: String?, persist: Bool,
                       opening target: RelatedThreadTarget? = nil) {
        stopConnection()
        if environment?.id != saved.id { clearWorkspace() }
        environment = saved
        relatedLanding = target
        currentServerID = nil
        connection = .connecting
        connectionError = nil
        onChange?(.all)
        let generation = self.generation
        connectionTask = Task { [weak self] in
            await self?.runConnection(saved, credential: credential, token: token, persist: persist, generation: generation)
        }
    }

    private func runConnection(_ saved: SavedEnvironment, credential: String?, token: String?, persist: Bool,
                               generation: UUID) async {
        var environment = saved
        var api = EnvironmentAPI(origin: saved.origin, token: token)
        var retryDelay = 1
        while !Task.isCancelled && generation == self.generation {
            do {
                if let route = saved.relay {
                    guard let relayClient else { throw ClientError.http(401, "T3 Connect is unavailable in this build.") }
                    let connected = try await relayClient.connect(route)
                    try Task.checkCancellation()
                    environment = SavedEnvironment(origin: connected.access.endpoint.origin, name: connected.label, relay: route)
                    api = EnvironmentAPI(origin: environment.origin, relay: connected.access)
                } else if api.token == nil {
                    guard let credential else {
                        throw ClientError.http(401, "Pair this environment again to connect.")
                    }
                    api.token = try await api.exchange(credential)
                    try Task.checkCancellation()
                    if persist, let token = api.token {
                        do { try EnvironmentKeychain.save(token, for: saved.origin) }
                        catch { onError?(error.localizedDescription) }
                    }
                    if let descriptor = try? await api.http("/.well-known/t3/environment") {
                        let label = descriptor["label"].string.flatMap { $0.isEmpty ? nil : $0 } ?? saved.name
                        environment = SavedEnvironment(origin: saved.origin, name: label, serverID: descriptor["environmentId"].string)
                    }
                }
                let state = try await api.http("/api/auth/session")
                guard state["authenticated"].bool == true else {
                    throw ClientError.http(401, saved.relay == nil ? "This session expired. Pair the environment again." :
                                            "This T3 Connect session expired. Sign in and reconnect.")
                }
                let socket = try await api.connect()
                guard !Task.isCancelled, generation == self.generation else {
                    await socket.close()
                    return
                }
                self.socket = socket
                socketID = UUID()
                self.api = api
                self.auth = state
                currentServerID = environment.relay?.environmentID ?? (credential != nil ? environment.serverID : nil)
                self.environment = environment
                if persist {
                    environments.removeAll { $0.id == environment.id }
                    environments.append(environment)
                    preferences?.set(environment.id, forKey: "activeEnvironment")
                    storeEnvironments()
                }
                let config = Task { await self.readProviders(from: socket) }
                let renewal = api.relay.map { access in Task { await access.client.keepAlive(access) } }
                defer { config.cancel(); renewal?.cancel() }
                var payload: Payload = [:]
                if let sequence = data.sequence {
                    payload = ["afterSequence": .int(sequence), "requestCompletionMarker": .bool(true)]
                }
                let shell = try await socket.subscribe("orchestration.subscribeShell", payload)
                for try await chunk in shell {
                    try Task.checkCancellation()
                    receiveShell(chunk.values)
                    retryDelay = 1
                    try await socket.acknowledge(chunk)
                }
                throw ClientError.disconnected
            } catch {
                guard !Task.isCancelled, generation == self.generation else { return }
                if let socket = self.socket { await socket.close() }
                guard !Task.isCancelled, generation == self.generation else { return }
                socket = nil
                self.api = nil
                voiceInput.cancel()
                supportsServerBrowser = false
                browserProfileReporter.reset()
                browserProfileClear = nil
                draftFileCheckout?.task.cancel()
                draftFileCheckout = nil
                finishModelSwitchWaits()
                threadTask?.cancel()
                sideChatTask?.cancel()
                finishSideChatWaits()
                archiveTask?.cancel()
                cloneTask?.cancel()
                cloneTask = nil
                cloneList.clearStarting()
                connectionError = error.localizedDescription
                if (error as? ClientError)?.requiresPairing == true || (saved.relay == nil && api.token == nil) {
                    relatedLanding = nil
                    connection = .needsPairing
                    onChange?(.connection)
                    return
                }
                connection = .retrying
                onChange?(.connection)
                if let route = saved.relay { await relayClient?.forget(route) }
                do { try await Task.sleep(for: .seconds(retryDelay)) }
                catch { return }
                retryDelay = min(15, retryDelay * 2)
            }
        }
    }

    private func readProviders(from socket: RPCSocket) async {
        do {
            let stream = try await socket.subscribe("subscribeServerConfig", [
                "workspaceSnapshotsOnDemand": .bool(true), "usageLimitSources": .bool(true),
            ])
            for try await chunk in stream {
                guard self.socket === socket, !Task.isCancelled else { return }
                var change: Change = .providers
                for event in chunk.values {
                    if event["type"].string == "snapshot" {
                        applyServerConfig(event["config"])
                        change.insert(.sidebar)
                    } else {
                        let payload = event["payload"]
                        switch event["type"].string {
                        case "usageLimitSourcesUpdated":
                            usageLimitSnapshots = payload["sources"].array.compactMap(UsageLimitSource.init)
                        case "settingsUpdated":
                            applyServerSettings(payload["settings"])
                        default:
                            if payload["providers"] != .null {
                                providers = payload["providers"].array.compactMap(Provider.init)
                            }
                        }
                    }
                }
                syncDraftFileCheckout()
                onChange?(change)
                try await socket.acknowledge(chunk)
            }
        } catch {
            guard self.socket === socket, !Task.isCancelled else { return }
            if let config = try? await socket.request("server.getConfig"), self.socket === socket {
                applyServerConfig(config)
                syncDraftFileCheckout()
                onChange?([.providers, .sidebar])
            }
        }
    }

    private func applyServerConfig(_ config: Wire) {
        if let id = config["environment"]["environmentId"].string, !id.isEmpty {
            currentServerID = id
            if environment?.serverID != id {
                environment?.serverID = id
                if let active = environment, let index = environments.firstIndex(where: { $0.id == active.id }) {
                    environments[index].serverID = id
                    storeEnvironments()
                }
            }
            resolveRelatedLanding()
        }
        scratchWorkspaceRoot = config["scratchWorkspaceRoot"].string
        newProjectsRoot = config["newProjectsRoot"].string
        providers = config["providers"].array.compactMap(Provider.init)
        usageLimitSnapshots = config["usageLimitSources"].array.compactMap(UsageLimitSource.init)
        usageHubSettings.supportsReferences = config["secretReferences"].bool == true
        applyServerSettings(config["settings"])
        environmentPlatform = config["environment"]["platform"]["os"].string
        supportsFreshContext = config["environment"]["capabilities"]["freshContext"].bool == true
        supportsQuestionAttachments = config["environment"]["capabilities"]["questionAttachments"].bool == true
        supportsSideChats = config["environment"]["capabilities"]["sideChats"].bool == true
        supportsThreadFamilies = config["shellThreadFamilies"].bool == true
        supportsProjectOrganization = config["environment"]["capabilities"]["projectOrganization"].bool == true
        supportsProjectCloneTracking = config["environment"]["capabilities"]["projectCloneTracking"].bool == true
        supportsServerBrowser = config["environment"]["capabilities"]["serverBrowser"].bool == true
        supportsVoiceTranscription = config["environment"]["capabilities"]["voiceTranscription"].bool == true
        supportsCloudVoiceTranscription = config["environment"]["capabilities"]["cloudVoiceTranscription"].bool == true
        voiceInput.invalidate(target: supportsVoiceDestination(voicePreferences.cloud) ? voiceTarget : nil,
                              grant: voicePreferences.grant, cleanupGrant: voicePreferences.cleanupGrant)
        reportBrowserProfiles()
        threadFindEnabled = config["threadFind"].bool == true
        threadFindProgressive = config["threadFindProgressive"].bool == true
        sharingConfiguration = SharingConfiguration(config)
        if let socket { subscribeProjectClones(on: socket) }
    }

    private func applyServerSettings(_ settings: Wire) {
        usageModelFilter = settings["usageModelFilter"]
        projectPreferences = ProjectPreferences(settings)
        projectOnboardingSettings = ProjectOnboardingSettings(settings)
        providerConfigurations = settings["providerInstances"].object
        usageHubSettings.apply(settings)
        deviceHostSettings = DeviceHostSettings(settings)
        guestSharingEnabled = settings["guestSharingEnabled"].bool
        speechWords = settings["speechProjectCustomWords"]
        projectSpeechWords = settings["projectSettingsOverrides"]
        voiceCleanupModel = settings["speechPostProcessingModelSelection"]
        voiceTextGenerationModel = settings["textGenerationModelSelection"]
        voiceCloudReferences = Dictionary(uniqueKeysWithValues: VoiceCloudProvider.allCases.compactMap { provider in
            SettingsSecretReference(settings["cloudSpeechCredentials"][provider.rawValue]).map { (provider, $0) }
        })
    }

    func setGuestSharingEnabled(_ enabled: Bool, connection: UUID) async throws {
        guard connectionID == connection, can("settings:write"), let previous = guestSharingEnabled,
              !enabled || !sharingConfiguration.blocksConnect else { throw ClientError.disconnected }
        let result = try await request("server.updateSettings", ["patch": .object(["guestSharingEnabled": .bool(enabled)])])
        guard connectionID == connection else { throw ClientError.disconnected }
        if guestSharingEnabled == previous, let current = result["guestSharingEnabled"].bool {
            guestSharingEnabled = current
            onChange?(.providers)
        }
    }

    func acceptUsageHubSettings(_ settings: Wire, replacing previous: UsageHubSettings) {
        guard usageHubSettings == previous, settings["usageLimitSources"].object != nil else { return }
        usageHubSettings.apply(settings)
        onChange?(.providers)
    }

    func acceptDeviceHostSettings(_ settings: Wire, replacing previous: DeviceHostSettings) {
        guard deviceHostSettings == previous, settings["deviceHosts"] != .null else { return }
        deviceHostSettings = DeviceHostSettings(settings)
        onChange?(.providers)
    }

    func acceptProviderConfigurations(_ settings: Wire, replacing previous: Payload) {
        guard providerConfigurations == previous, let next = settings["providerInstances"].object else { return }
        providerConfigurations = next
        onChange?(.providers)
    }

    private func subscribeProjectClones(on socket: RPCSocket) {
        guard supportsProjectCloneTracking, cloneTask == nil else { return }
        cloneTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.socket === socket { cloneTask = nil } }
            do {
                let stream = try await socket.subscribe("subscribeProjectClones")
                var first = true
                for try await chunk in stream {
                    guard !Task.isCancelled, self.socket === socket else { return }
                    let previous = cloneList.blockedPhases
                    var changed = false
                    for frame in chunk.values {
                        guard case .array = frame else { continue }
                        changed = cloneList.apply(frame, reconnecting: first) || changed
                        first = false
                    }
                    if changed { notifyClones(previous: previous) }
                    try await socket.acknowledge(chunk)
                }
            } catch { }
        }
    }

    private func notifyClones(previous: [String: ProjectCloneStatus.Phase]) {
        if previous == cloneList.blockedPhases { onChange?(.clones) }
        else {
            syncDraftFileCheckout()
            onChange?([.clones, .sidebar])
        }
    }

    private func receiveShell(_ frames: [Wire]) {
        for frame in frames { data.apply(frame) }
        for (id, waiter) in sideChatWaiters where data.threads[id]?.isSideChat == true { waiter.finish() }
        if let sideChat, data.threads[sideChat.threadID]?.parentThreadID != sideChat.parentID { clearSideChat() }
        for (threadID, waiter) in modelSwitchWaiters {
            let thread = data.threads[threadID]
            if thread?.activeRunId != waiter.runID && thread?.status != "waiting" { waiter.ended.finish() }
        }
        guard data.sequence != nil else { return }
        var change: Change = .sidebar
        if frames.contains(where: { ["snapshot", "project.updated", "project.removed"].contains($0["kind"].string) }) {
            change.insert(.projects)
        }
        if connection != .ready {
            connection = .ready
            connectionError = nil
            change.insert(.connection)
            reportBrowserProfiles()
            if let selection { subscribeToThread(selection) }
            if sideChat != nil { subscribeToSideChat() }
            if isShowingArchive { refreshArchive() }
        }
        if case .project(let id) = selection, data.projects[id]?.archived == true { select(nil) }
        else if let selection, frames.contains(where: { frame in
            switch selection {
            case .project(let id): frame["kind"].string == "project.removed" && frame["projectId"].string == id
            case .thread(let id): !isShowingArchive && frame["kind"].string == "thread.removed" && frame["threadId"].string == id
            }
        }) { select(nil) }
        if let environmentID = environment?.id {
            for frame in frames where frame["kind"].string == "project.removed" {
                guard let id = frame["projectId"].string, data.projects[id] == nil else { continue }
                draftCheckouts[environmentID]?.removeValue(forKey: id)
                sendAttempts.removeValue(forKey: .project(id))
            }
        }
        if selection == nil, !isShowingArchive, relatedLanding == nil {
            if let environmentID = environment?.id, let id = preferences?.string(forKey: "lastThread.\(environmentID)"),
               let thread = data.threads[id], data.isListed(thread) {
                select(.thread(id))
            } else if let project = firstProject {
                selection = .project(project.id)
                change.insert(.selection)
            }
        }
        if isShowingArchive && frames.contains(where: {
            $0["kind"].string == "thread.removed" || $0["location"].string == "archive"
        }) { refreshArchive() }
        syncDraftFileCheckout()
        resolveRelatedLanding()
        onChange?(change)
        if let onThreadShellChange {
            var threads = Set<String>()
            for frame in frames {
                switch frame["kind"].string {
                case "snapshot" where frame["resolvedRepositoryIdentityRoots"] == .null:
                    onThreadShellChange(.snapshot)
                    return
                case "thread.updated":
                    if let id = frame["thread"]["id"].string { threads.insert(id) }
                case "thread.removed":
                    if let id = frame["threadId"].string { threads.insert(id) }
                default: break
                }
            }
            if !threads.isEmpty { onThreadShellChange(.threads(threads)) }
        }
    }

    private func stopConnection() {
        generation = UUID()
        supportsServerBrowser = false
        supportsVoiceTranscription = false
        supportsCloudVoiceTranscription = false
        voiceInput.cancel()
        browserProfileReporter.reset()
        browserProfileClear = nil
        relatedLanding = nil
        currentServerID = nil
        connectionTask?.cancel()
        threadTask?.cancel()
        sideChatTask?.cancel()
        finishSideChatWaits()
        archiveTask?.cancel()
        cloneTask?.cancel()
        cloneTask = nil
        cloneList.clearStarting()
        draftFileCheckout?.task.cancel()
        draftFileCheckout = nil
        if let socket { Task { await socket.close() } }
        socket = nil
        api = nil
        finishModelSwitchWaits()
        auth = .null
        commandCatalogs.removeAll()
    }

    private func finishModelSwitchWaits() {
        for waiter in modelSwitchWaiters.values { waiter.ended.finish() }
        modelSwitchWaiters.removeAll()
    }

    private func clearWorkspace() {
        selection = nil
        detail = ThreadDetail()
        detailError = nil
        clearSideChat()
        data = WorkspaceData()
        providers = []
        providerConfigurations = nil
        usageLimitSnapshots = []
        usageHubSettings = UsageHubSettings()
        usageModelFilter = .null
        projectPreferences = ProjectPreferences()
        projectOnboardingSettings = ProjectOnboardingSettings()
        deviceHostSettings = DeviceHostSettings()
        environmentPlatform = nil
        supportsProjectCloneTracking = false
        cloneList = ProjectCloneList()
        supportsFreshContext = false
        supportsQuestionAttachments = false
        supportsSideChats = false
        supportsThreadFamilies = false
        supportsProjectOrganization = false
        threadFindEnabled = false
        threadFindProgressive = false
        sharingConfiguration = SharingConfiguration()
        guestSharingEnabled = nil
        speechWords = .null
        projectSpeechWords = .null
        voiceCleanupModel = .null
        voiceTextGenerationModel = .null
        voiceCloudReferences = [:]
        scratchWorkspaceRoot = nil
        newProjectsRoot = nil
        sending = []
        sendAttempts = [:]
        isShowingArchive = false
        activeSelection = nil
    }

    private func storeEnvironments() {
        preferences?.set(try? JSONEncoder().encode(environments), forKey: "environments")
    }

    func select(_ newSelection: Selection?) {
        guard newSelection != selection else { return }
        relatedLanding = nil
        selection = newSelection
        clearSideChat()
        detail = ThreadDetail()
        detailError = nil
        if !isShowingArchive, let environmentID = environment?.id, case .thread(let id) = newSelection {
            preferences?.set(id, forKey: "lastThread.\(environmentID)")
        }
        subscribeToThread(newSelection)
        syncDraftFileCheckout()
        onChange?([.selection, .timeline])
    }

    private func subscribeToThread(_ selection: Selection?) {
        threadTask?.cancel()
        guard case .thread(let id) = selection, let socket else { return }
        var payload: Payload = ["threadId": .string(id), "acceptBoundedSnapshot": .bool(true)]
        if detail.loaded, detail.sequence >= 0 {
            payload["afterSequence"] = .int(detail.sequence)
            payload["requestCompletionMarker"] = .bool(true)
        }
        threadTask = Task {
            do {
                let stream = try await socket.subscribe("orchestration.subscribeThread", payload)
                for try await chunk in stream {
                    guard !Task.isCancelled, self.socket === socket else { return }
                    for frame in chunk.values { detail.apply(frame) }
                    detailError = nil
                    onChange?(.timeline)
                    try await socket.acknowledge(chunk)
                }
            } catch {
                guard !Task.isCancelled, self.socket === socket else { return }
                detailError = error.localizedDescription
                onChange?(.timeline)
            }
        }
    }

    func retryThread() {
        subscribeToThread(selection)
    }

    func loadEarlier(throughEntryID: String? = nil, inSideChat: Bool = false) async throws {
        let visibleSide = inSideChat ? sideChat : nil
        let threadID: String? = if inSideChat { visibleSide?.threadID }
        else if case .thread(let id) = selection { id }
        else { nil }
        guard let id = threadID, let cursor = presentedDetail(for: id)?.historyCursor, let api else { return }
        let generation = self.generation
        let connection = connectionID
        var query = [
            URLQueryItem(name: "cursor", value: cursor), URLQueryItem(name: "view", value: "conversation"),
        ]
        if let throughEntryID { query.append(URLQueryItem(name: "throughEntryId", value: throughEntryID)) }
        let page = try await api.http("/api/orchestration/threads/\(id)/history", query: query)
        try Task.checkCancellation()
        guard generation == self.generation, connectionID == connection,
              presentedDetail(for: id)?.historyCursor == cursor else { return }
        if inSideChat {
            guard sideChat == visibleSide else { return }
            sideChatDetail.prepend(page)
            onChange?(.sideChat)
        } else {
            guard selection == .thread(id) else { return }
            detail.prepend(page)
            onChange?(.timeline)
        }
    }

    func presentedDetail(for threadID: String) -> ThreadDetail? {
        if selection == .thread(threadID) { return detail }
        if sideChat?.threadID == threadID { return sideChatDetail }
        return nil
    }

    @discardableResult
    func presentSideChat(_ reference: SideChatReference) -> Bool {
        guard reference.environmentID == environment?.id, reference.parentID == selectedThread?.id,
              data.threads[reference.threadID]?.isSideChat == true,
              data.threads[reference.threadID]?.parentThreadID == reference.parentID,
              can("orchestration:read") else { return false }
        guard sideChat != reference else { return true }
        clearSideChat()
        sideChat = reference
        subscribeToSideChat()
        onChange?(.sideChat)
        return true
    }

    func hideSideChat() {
        guard sideChat != nil else { return }
        clearSideChat()
        onChange?(.sideChat)
    }

    private func clearSideChat() {
        sideChatTask?.cancel()
        sideChatTask = nil
        sideChat = nil
        sideChatDetail = ThreadDetail()
        sideChatError = nil
    }

    func subscribeToSideChat() {
        sideChatTask?.cancel()
        guard let reference = sideChat, let connection = connectionID, can("orchestration:read") else { return }
        var payload: Payload = ["threadId": .string(reference.threadID), "acceptBoundedSnapshot": .bool(true)]
        if sideChatDetail.loaded, sideChatDetail.sequence >= 0 {
            payload["afterSequence"] = .int(sideChatDetail.sequence)
            payload["requestCompletionMarker"] = .bool(true)
        }
        sideChatTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await subscribe("orchestration.subscribeThread", payload) { frames in
                    guard !Task.isCancelled, sideChat == reference, connectionID == connection else { return }
                    for frame in frames { sideChatDetail.apply(frame) }
                    sideChatError = nil
                    onChange?(.sideChat)
                }
            } catch {
                guard !Task.isCancelled, sideChat == reference, connectionID == connection else { return }
                sideChatError = error.localizedDescription
                onChange?(.sideChat)
            }
        }
    }

    func awaitSideChatShell(_ reference: SideChatReference, connection: UUID) async throws -> ThreadSummary {
        guard connectionID == connection else { throw ClientError.disconnected }
        if let thread = data.threads[reference.threadID], thread.isSideChat, thread.parentThreadID == reference.parentID { return thread }
        let (ready, waiter) = AsyncStream<Void>.makeStream()
        sideChatWaiters[reference.threadID] = waiter
        defer { waiter.finish(); sideChatWaiters.removeValue(forKey: reference.threadID) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in ready {} }
            group.addTask { try await Task.sleep(for: .seconds(15)); throw ClientError.timedOut }
            defer { group.cancelAll() }
            try await group.next()
        }
        try Task.checkCancellation()
        guard connectionID == connection, let thread = data.threads[reference.threadID],
              thread.isSideChat, thread.parentThreadID == reference.parentID else { throw ClientError.disconnected }
        return thread
    }

    private func finishSideChatWaits() {
        for waiter in sideChatWaiters.values { waiter.finish() }
        sideChatWaiters.removeAll()
    }

    func forkThread(from entry: TimelineEntry) async throws -> Bool {
        guard let thread = selectedThread, let connection = connectionID, can("orchestration:operate"),
              entry.canFork, let runID = entry.value["runId"].string,
              detail.timeline.contains(where: { $0.id == entry.id && $0.sourceThreadID == entry.sourceThreadID }) else { return false }
        let target = UUID().uuidString
        _ = try await request("orchestration.dispatchCommand", [
            "type": .string("thread.fork"), "commandId": .string(UUID().uuidString),
            "sourceThreadId": .string(entry.sourceThreadID), "targetThreadId": .string(target),
            "createdBy": .string("user"), "creationSource": .string("web"),
            "sourcePoint": .object(["type": .string("run"), "runId": .string(runID)]),
            "title": .string("\(thread.title) fork"),
        ])
        guard connectionID == connection, selection == .thread(thread.id) else { return false }
        showArchive(false)
        select(.thread(target))
        return true
    }

    func prepareRewind(from entry: TimelineEntry) async throws -> ThreadRewind.Plan {
        guard let thread = selectedThread, let connection = connectionID, can("orchestration:operate"),
              !thread.archived, !thread.isWorking, !sending.contains(.thread(thread.id)), entry.canRewind else {
            throw ClientError.message("Stop the current turn before editing an earlier message.")
        }
        let projection = try await request("orchestration.getThreadProjection", ["threadId": .string(thread.id)])
        guard connectionID == connection else { throw ClientError.disconnected }
        return try ThreadRewind.prepare(projection, message: entry)
    }

    func rewind(_ plan: ThreadRewind.Plan, restoreFiles: Bool) async throws {
        let destination = Selection.thread(plan.threadID)
        guard let socket, let connection = connectionID, can("orchestration:operate"),
              data.threads[plan.threadID]?.archived == false, data.threads[plan.threadID]?.isWorking == false,
              !sending.contains(destination) else { throw ClientError.disconnected }
        sending.insert(destination)
        onChange?(.selection)
        defer {
            if connectionID == connection {
                sending.remove(destination)
                onChange?(.selection)
            }
        }
        let projection = try await request("orchestration.getThreadProjection", ["threadId": .string(plan.threadID)])
        guard connectionID == connection, let source = projection["visibleTurnItems"].array.compactMap(TimelineEntry.init(row:))
            .first(where: { $0.id == plan.entryID }), try ThreadRewind.prepare(projection, message: source) == plan else {
            throw ClientError.message("The conversation changed. Choose the message again.")
        }
        let requestID = UUID().uuidString
        let stream = try await socket.subscribe("orchestration.subscribeThread", [
            "threadId": .string(plan.threadID), "acceptBoundedSnapshot": .bool(true),
        ])
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var state = ThreadRewind.State()
                state.load(projection)
                var accepted = false
                for try await chunk in stream {
                    var initialSnapshot: Wire?
                    for frame in chunk.values {
                        if frame["kind"].string == "snapshot" {
                            state.load(frame["projection"])
                            initialSnapshot = frame["projection"]
                        }
                        else if frame["kind"].string == "event" {
                            state.apply(frame["event"]["type"].string, frame["event"]["payload"])
                        }
                    }
                    try await socket.acknowledge(chunk)
                    if !accepted, let initialSnapshot {
                        guard initialSnapshot["thread"]["id"].string == plan.threadID,
                              initialSnapshot["thread"]["activeProviderThreadId"].string == plan.providerThreadID,
                              !initialSnapshot["runs"].array.contains(where: {
                                  ThreadSummary.working.contains($0["status"].string ?? "") && $0["status"].string != "queued"
                              }) else {
                            throw ClientError.message("The conversation started another turn. Choose the message again.")
                        }
                        _ = try await socket.request("orchestration.dispatchCommand", [
                            "type": .string("checkpoint.rollback"), "threadId": .string(plan.threadID),
                            "commandId": .string(requestID), "scopeId": .string(plan.scopeID),
                            "checkpointId": .string(plan.checkpointID), "restoreFiles": .bool(restoreFiles),
                        ])
                        accepted = true
                    }
                    if accepted, let result = state.outcome(for: plan, requestID: requestID) { return try result.get() }
                }
                throw ClientError.disconnected
            }
            group.addTask {
                try await Task.sleep(for: .seconds(120))
                throw ClientError.message("Timed out waiting for the conversation to rewind.")
            }
            defer { group.cancelAll() }
            try await group.next()
        }
        try Task.checkCancellation()
        guard connectionID == connection else { throw ClientError.disconnected }
    }

    func openRelatedThread(_ id: String, activeOnly: Bool = false) async throws {
        guard let connection = connectionID, can("orchestration:read") else { throw ClientError.disconnected }
        let previous = selection
        if data.threads[id] == nil && data.archived[id] == nil {
            let titles = try await request("orchestration.getThreadTitles", ["threadIds": .array([.string(id)])])
            guard connectionID == connection, selection == previous else { return }
            guard titles[id].string != nil else { throw ClientError.message("The related conversation is no longer available.") }
        }
        if activeOnly, data.threads[id] == nil, data.archived[id] != nil {
            throw ClientError.message("The matching conversation was archived.")
        }
        showArchive(!activeOnly && data.threads[id] == nil)
        select(.thread(id))
    }

    private func resolveRelatedLanding() {
        guard let target = relatedLanding, let connection = connectionID, let currentServerID else { return }
        relatedLanding = nil
        guard target.environmentID == currentServerID else {
            if selection == nil, let project = firstProject { select(.project(project.id)) }
            onError?("The connected environment has a different identity than this conversation’s source.")
            return
        }
        Task { [weak self] in
            guard let self, self.connectionID == connection else { return }
            do { try await openRelatedThread(target.threadID) }
            catch { if self.connectionID == connection { onError?(error.localizedDescription) } }
        }
    }

    func fileChangeDetail(_ entry: TimelineEntry) async throws -> Wire {
        guard let connection = connectionID, can("orchestration:read") else { throw ClientError.disconnected }
        var payload: Payload = ["threadId": .string(entry.sourceThreadID), "itemId": .string(entry.id)]
        if let revision = entry.value["updatedAt"].string { payload["revision"] = .string(revision) }
        let response = try await request("orchestration.getTurnItem", payload)
        guard connectionID == connection else { throw ClientError.disconnected }
        let item = response["item"]
        guard item == .null || item["type"].string == "file_change" else { throw ClientError.invalidResponse }
        return item
    }

    func showArchive(_ show: Bool) {
        guard show != isShowingArchive else { return }
        isShowingArchive = show
        if show {
            activeSelection = selection
            select(nil)
            refreshArchive()
        } else {
            archiveTask?.cancel()
            switch activeSelection {
            case .thread(let id) where data.threads[id] != nil: select(activeSelection)
            case .project(let id) where data.projects[id]?.archived == false: select(activeSelection)
            default: select(firstProject.map { .project($0.id) })
            }
            activeSelection = nil
        }
        onChange?(.sidebar)
    }

    private var firstProject: Project? {
        data.projects.values.filter { !$0.archived }.min(by: Project.precedes)
    }

    private func refreshArchive() {
        archiveTask?.cancel()
        archiveTask = Task {
            do {
                let snapshot = try await request("orchestration.getArchivedShellSnapshot")
                guard !Task.isCancelled, isShowingArchive else { return }
                if data.replaceArchive(snapshot) { onChange?([.sidebar, .projects]) }
            } catch {
                guard !Task.isCancelled else { return }
                onError?(error.localizedDescription)
            }
        }
    }

    func can(_ scope: String) -> Bool {
        guard connection == .ready else { return false }
        let scopes = auth["scopes"].array.compactMap(\.string)
        if auth["permissions"] != .null { return auth["permissions"].array.contains(.string(scope)) }
        if scopes.contains(scope) { return true }
        guard auth["auth"]["serverUpdateScope"] == .null else { return false }
        switch scope {
        case "filesystem:read": return scopes.contains("orchestration:read")
        case "terminal:read": return scopes.contains("terminal:operate")
        case "providers:manage", "filesystem:write", "settings:write", "preview:operate", "source-control:write":
            return scopes.contains("orchestration:operate")
        default: return false
        }
    }

    var delegatablePairingScopes: [String] {
        can("access:write") ? PairingScope.grantedBy(auth) : []
    }

    func mutateSharingAccess(_ mutation: SharingAccessMutation, connection: UUID) async throws -> Wire {
        guard connectionID == connection, let api, can("access:write") else { throw ClientError.disconnected }
        if case .createLink(_, let scopes) = mutation {
            guard !sharingConfiguration.blocksRemoteClients else {
                throw ClientError.message("This environment’s policy restricts access from other devices.")
            }
            let delegated = Set(scopes)
            guard !delegated.isEmpty, delegated.count == scopes.count, delegated.isSubset(of: Set(delegatablePairingScopes)) else {
                throw ClientError.message("Choose permissions held by this connection.")
            }
        }
        let request = mutation.request
        let body = try request.payload.map { try JSONEncoder().encode(Wire.object($0)) }
        let result = try await api.http(request.path, method: "POST", body: body,
                                        contentType: body == nil ? nil : "application/json")
        guard connectionID == connection else { throw ClientError.disconnected }
        return result
    }

    func request(_ method: String, _ payload: Payload = [:], timeout: Duration = .seconds(120)) async throws -> Wire {
        guard let socket, connection == .ready else { throw ClientError.disconnected }
        return try await socket.request(method, payload, timeout: timeout)
    }

    func readWorkspaceFile(_ target: WorkspaceFileTarget, connection: UUID) async throws -> WorkspaceFileContents {
        guard environment?.id == target.environmentID, connectionID == connection, can("filesystem:read") else {
            throw ClientError.disconnected
        }
        let result = try await request("projects.readFile", target.request)
        try Task.checkCancellation()
        guard connectionID == connection, can("filesystem:read") else { throw ClientError.disconnected }
        return try WorkspaceFileContents(result)
    }

    func writeWorkspaceFile(_ target: WorkspaceFileTarget, contents: String, connection: UUID) async throws {
        guard target.path.workspaceRelative != nil else { throw ClientError.message("Host files outside the workspace are read-only.") }
        guard environment?.id == target.environmentID, connectionID == connection,
              can("filesystem:read"), can("filesystem:write") else { throw ClientError.disconnected }
        var payload = target.request
        payload["contents"] = .string(contents)
        _ = try await request("projects.writeFile", payload)
        guard connectionID == connection else { throw ClientError.disconnected }
        if target.path.workspaceRelative == "t3.json", draftFileCheckout?.scope.root == target.root {
            syncDraftFileCheckout(refresh: true)
            onChange?(.selection)
        }
    }

    func downloadWorkspaceFile(_ target: WorkspaceFileTarget, connection: UUID) async throws -> AttachmentFile {
        guard environment?.id == target.environmentID, connectionID == connection, can("filesystem:read"),
              let api else { throw ClientError.disconnected }
        let grant = try await request("assets.createUrl", ["resource": target.previewResource])
        try Task.checkCancellation()
        guard connectionID == connection, can("filesystem:read") else { throw ClientError.disconnected }
        let temporary = try await api.downloadAsset(grant.requireString("relativeUrl"))
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard connectionID == connection, can("filesystem:read") else { throw ClientError.disconnected }
        return try AttachmentFile(temporaryFile: temporary, name: AttachmentFile.safeName(target.name))
    }

    func composerCommands(for scope: ComposerCommandScope) async throws -> ComposerCommandCatalog {
        guard connectionID == scope.connection, can("orchestration:read") else { throw ClientError.disconnected }
        if let cached = commandCatalogs[scope], cached.expires > .now { return cached.catalog }
        let result = try await request("server.refreshProviders", [
            "instanceId": .string(scope.instanceID), "cwd": .string(scope.cwd), "workspaceSnapshotsOnDemand": .bool(true),
        ])
        try Task.checkCancellation()
        guard connectionID == scope.connection else { throw ClientError.disconnected }
        let provider = result["providers"].array.first { $0["instanceId"].string == scope.instanceID }
        let snapshot = provider?["workspaceSnapshots"].array.first { $0["cwd"].string == scope.cwd }
        let catalog = snapshot.map(ComposerCommandCatalog.init) ??
            providers.first(where: { $0.id == scope.instanceID })?.commandCatalog ?? .init()
        commandCatalogs = commandCatalogs.filter { $0.value.expires > .now }
        commandCatalogs[scope] = (catalog, .now + .seconds(catalog.pending ? 10 : 300))
        return catalog
    }

    func subscribe(_ method: String, _ payload: Payload, onSubscribe: (() -> Void)? = nil,
                   receive: ([Wire]) -> Void) async throws {
        guard let socket, connection == .ready else { throw ClientError.disconnected }
        let stream = try await socket.subscribe(method, payload)
        onSubscribe?()
        for try await chunk in stream {
            try Task.checkCancellation()
            receive(chunk.values)
            try await socket.acknowledge(chunk)
        }
    }

    func browserAPI(for environmentID: String) throws -> EnvironmentAPI {
        guard let api, environment?.id == environmentID, can("orchestration:read") else { throw ClientError.disconnected }
        return api
    }

    var t3ConnectHostTarget: T3ConnectHostTarget? {
        guard can("relay:read"), let connection = connectionID, let environment, let serverID = currentServerID else { return nil }
        let origin = environment.relay == nil && environment.isLocal ? environment.origin : nil
        return .init(connection: connection, environmentID: environment.id, serverID: serverID, localOrigin: origin)
    }

    func t3ConnectHostRequest(_ route: T3ConnectHostRoute, target: T3ConnectHostTarget, payload: Payload? = nil) async throws -> Wire {
        guard t3ConnectHostTarget == target, can(route.scope), let api else { throw ClientError.disconnected }
        let body = try payload.map { try JSONEncoder().encode(Wire.object($0)) }
        let reply = try await api.http("/api/connect/\(route.rawValue)", method: route == .state ? "GET" : "POST",
                                       body: body, contentType: body == nil ? nil : "application/json", timeout: 60)
        try Task.checkCancellation()
        guard t3ConnectHostTarget == target else { throw ClientError.disconnected }
        return reply
    }

    func pullRequestDiff(_ payload: Payload, connection: UUID) async throws -> Wire {
        guard connectionID == connection, let api, can("orchestration:read") else { throw ClientError.disconnected }
        let result = try await api.http("/api/pull-requests/diff", method: "POST", body: JSONEncoder().encode(Wire.object(payload)),
                                        contentType: "application/json", timeout: 60)
        guard connectionID == connection else { throw ClientError.disconnected }
        return result
    }

    func dispatch(_ type: String, threadId: String, _ fields: Payload = [:]) async throws {
        var payload = fields
        payload["type"] = .string(type)
        payload["threadId"] = .string(threadId)
        payload["commandId"] = payload["commandId"] ?? .string(UUID().uuidString)
        _ = try await request("orchestration.dispatchCommand", payload)
    }

    var projectOnboardingScope: ProjectOnboardingScope? {
        guard let environment, let connectionID else { return nil }
        return .init(environmentID: environment.id, connection: connectionID)
    }

    func browseProjectFolders(_ path: String, cwd: String?, scope: ProjectOnboardingScope) async throws -> ProjectFolderListing {
        guard projectOnboardingScope == scope, can("filesystem:read") else { throw ClientError.disconnected }
        var input: Payload = ["partialPath": .string(path)]
        if let cwd { input["cwd"] = .string(cwd) }
        let result = try await request("filesystem.browse", input)
        try Task.checkCancellation()
        guard projectOnboardingScope == scope else { throw ClientError.disconnected }
        return try ProjectFolderListing(result)
    }

    func cloneProviders(scope: ProjectOnboardingScope) async throws -> [CloneProviderChoice] {
        guard projectOnboardingScope == scope, can("orchestration:read") else { throw ClientError.disconnected }
        let result = try await request("server.discoverSourceControl")
        try Task.checkCancellation()
        guard projectOnboardingScope == scope else { throw ClientError.disconnected }
        return result["sourceControlProviders"].array.compactMap(CloneProviderChoice.init)
    }

    func lookupCloneRepository(_ reference: String, provider: String, scope: ProjectOnboardingScope) async throws -> CloneRepository {
        guard projectOnboardingScope == scope, can("orchestration:read") else { throw ClientError.disconnected }
        let result = try await request("sourceControl.lookupRepository", ["provider": .string(provider), "repository": .string(reference)])
        try Task.checkCancellation()
        guard projectOnboardingScope == scope else { throw ClientError.disconnected }
        return try CloneRepository(result)
    }

    func addProject(_ path: String, name: String, scope suppliedScope: ProjectOnboardingScope? = nil,
                    attempt: ProjectAddAttempt = .init(), createIfMissing: Bool = false) async throws {
        guard let scope = suppliedScope ?? projectOnboardingScope, projectOnboardingScope == scope,
              can("orchestration:operate") else { throw ClientError.disconnected }
        if let existing = data.projects.values.first(where: { ProjectHostPath.matches($0.root, path, platform: environmentPlatform) }) {
            guard !existing.archived else { throw ClientError.message("Restore this project in Project Settings before opening it.") }
            openOnboardedProject(existing.id)
            return
        }
        let project = try await request("projects.mutate", [
            "type": .string("project.create"), "commandId": .string(attempt.commandID),
            "projectId": .string(attempt.projectID), "workspaceRoot": .string(path), "title": .string(name),
            "createWorkspaceRootIfMissing": .bool(createIfMissing),
        ])
        guard projectOnboardingScope == scope else { throw ClientError.disconnected }
        openOnboardedProject(project["id"].string ?? attempt.projectID)
    }

    func createProject(name: String, scope: ProjectOnboardingScope) async throws -> String? {
        guard projectOnboardingScope == scope, can("orchestration:operate"), newProjectsRoot != nil else {
            throw ClientError.disconnected
        }
        let result = try await request("projects.createNew", ["name": .string(name)])
        guard projectOnboardingScope == scope else { throw ClientError.disconnected }
        let id = try result.requireString("projectId")
        openOnboardedProject(id)
        return result["commitError"].string.map { "Created \(name). Git could not make the first commit. \($0)" }
    }

    private func openOnboardedProject(_ id: String) {
        showArchive(false)
        select(.project(id))
    }

    func cloneStatus(_ id: String) -> ProjectCloneStatus? { cloneList.status(id) }

    func startProjectClone(remote: String, destination: String, title: String, transport: String,
                           scope: ProjectOnboardingScope, attempt: ProjectAddAttempt) async throws {
        guard projectOnboardingScope == scope, can("orchestration:operate"), can("source-control:write") else {
            throw ClientError.disconnected
        }
        if let project = data.projects[attempt.projectID], !project.archived {
            openOnboardedProject(project.id)
            return
        }
        var input: Payload = ["remoteUrl": .string(remote), "destinationPath": .string(destination), "protocol": .string(transport)]
        if !supportsProjectCloneTracking {
            let result = try await request("sourceControl.cloneRepository", input, timeout: .seconds(250))
            let folder = try result.requireString("cwd")
            do { try await addProject(folder, name: title, scope: scope, attempt: attempt) }
            catch { throw ClientError.message("The repository was cloned to \(folder). \(error.localizedDescription)") }
            return
        }
        if let socket { subscribeProjectClones(on: socket) }
        input["projectId"] = .string(attempt.projectID)
        input["title"] = .string(title)
        input["createdAt"] = .string(attempt.createdAt)
        let previous = cloneList.blockedPhases
        cloneList.markStarting(attempt.projectID)
        notifyClones(previous: previous)
        do {
            let result = try await request("projectClone.start", input)
            guard projectOnboardingScope == scope else { throw ClientError.disconnected }
            openOnboardedProject(try result.requireString("projectId"))
        } catch {
            if projectOnboardingScope == scope {
                let previous = cloneList.blockedPhases
                cloneList.clearStarting(attempt.projectID)
                notifyClones(previous: previous)
            }
            throw error
        }
    }

    func controlProjectClone(_ target: ProjectTarget, _ control: ProjectCloneControl) async throws -> Bool {
        guard projectTarget(target.id) == target, let status = cloneStatus(target.id), status.blocksCheckout else {
            throw ClientError.disconnected
        }
        switch control {
        case .remove:
            guard status.canRetry else { return false }
            try await mutateProject(target, type: "project.delete", fields: [:])
            return true
        case .cancel, .retry:
            guard can("source-control:write") else { throw ClientError.disconnected }
            let method: String
            if case .cancel = control {
                guard status.phase == .running else { return false }
                method = "projectClone.cancel"
            } else {
                guard status.canRetry else { return false }
                method = "projectClone.retry"
            }
            let result = try await request(method, ["projectId": .string(target.id)])
            guard connectionID == target.connection else { throw ClientError.disconnected }
            return result["applied"].bool == true
        }
    }

    func projectTarget(_ id: String) -> ProjectTarget? {
        guard let connectionID, data.projects[id] != nil, can("orchestration:read") else { return nil }
        return .init(id: id, connection: connectionID)
    }

    func projectFileScope(_ id: String) -> ProjectFileScope? {
        guard let target = projectTarget(id), let project = data.projects[id], can("filesystem:read"),
              cloneStatus(id)?.blocksCheckout != true else { return nil }
        return .init(target: target, root: project.root)
    }

    func readProjectFile(_ scope: ProjectFileScope) async throws -> ProjectFileConfiguration? {
        guard projectFileScope(scope.target.id) == scope else { throw ClientError.disconnected }
        let result = try await request("projects.readFile", [
            "cwd": .string(scope.root), "relativePath": .string("t3.json"), "allowMissing": .bool(true),
        ])
        try Task.checkCancellation()
        let parsed = await Task.detached(priority: .userInitiated) { ProjectFileConfiguration(result) }.value
        try Task.checkCancellation()
        guard projectFileScope(scope.target.id) == scope else { throw ClientError.disconnected }
        return parsed
    }

    func canEditProject(_ target: ProjectTarget) -> Bool {
        projectTarget(target.id) == target && can("orchestration:operate")
    }

    func canEditProjectDefaults(_ target: ProjectTarget) -> Bool {
        guard projectTarget(target.id) == target, projectPreferences.loaded else { return false }
        return projectPreferences.supportsOverrides ? can("settings:write") : can("orchestration:operate")
    }

    func projectActions(_ project: Project) -> [ProjectAction] {
        projectPreferences.value(.actions, for: project).array.compactMap(ProjectAction.init)
    }

    func changeProjectActions(_ target: ProjectTarget, _ change: ProjectActionChange) async throws {
        guard let project = data.projects[target.id], canEditProjectDefaults(target), can("settings:write") else {
            throw ClientError.disconnected
        }
        let value = try change.applying(to: projectPreferences.value(.actions, for: project).array)
        guard value != projectPreferences.override(.actions, for: project) else { return }
        try await setProjectDefault(.actions, value: value, target: target)
    }

    func changeProject(_ target: ProjectTarget, _ change: ProjectMetadataChange) async throws {
        switch change {
        case .pin, .archive:
            guard supportsProjectOrganization else { throw ClientError.message("This environment does not support project organization.") }
        case .rename: break
        }
        try await mutateProject(target, type: "project.update", fields: change.fields)
    }

    func removeProject(_ target: ProjectTarget) async throws {
        try await mutateProject(target, type: "project.delete", fields: ["force": .bool(true)])
    }

    func setProjectDefault(_ setting: ProjectPreferences.Setting, value: Wire?, target: ProjectTarget) async throws {
        guard canEditProjectDefaults(target), let project = data.projects[target.id] else { throw ClientError.disconnected }
        let previous = projectPreferences
        if setting == .actions, !can("settings:write") { throw ClientError.disconnected }
        if !previous.supportsOverrides {
            let legacy = value ?? (setting == .autoPull ? .bool(false) : setting == .actions ? .array([]) : .null)
            try await mutateProject(target, type: "project.update", fields: [setting.legacyKey: legacy])
            return
        }
        let patch = previous.patch(setting, value: value, for: project)
        let settings = try await request("server.updateSettings", ["patch": .object(patch)])
        guard connectionID == target.connection else { throw ClientError.disconnected }
        if projectPreferences == previous, settings["projectSettingsOverrides"].object != nil {
            projectPreferences = ProjectPreferences(settings)
            syncDraftFileCheckout()
            onChange?(.providers)
        }
    }

    private func mutateProject(_ target: ProjectTarget, type: String, fields: Payload) async throws {
        guard canEditProject(target) else { throw ClientError.disconnected }
        var payload = fields
        payload["type"] = .string(type)
        payload["projectId"] = .string(target.id)
        payload["commandId"] = .string(UUID().uuidString)
        _ = try await request("projects.mutate", payload)
        guard connectionID == target.connection else { throw ClientError.disconnected }
    }

    func startScratch() async throws {
        let generation = self.generation
        let response = try await request("projects.ensureScratch")
        let id = try response.requireString("projectId")
        guard self.generation == generation else { return }
        if let project = data.projects[id], project.archived {
            throw ClientError.message("Restore “\(project.name)” in Project Settings to start a chat.")
        }
        showArchive(false)
        select(.project(id))
    }

    func canEditQueue(threadID: String, connection: UUID) -> Bool {
        connectionID == connection && presentedDetail(for: threadID) != nil && data.threads[threadID]?.archived == false &&
            can("orchestration:operate")
    }

    func canAnswerQuestion(_ target: QuestionResponseTarget) -> Bool {
        guard environment?.id == target.environmentID, data.threads[target.threadID]?.archived == false, can("orchestration:operate"),
              let request = presentedDetail(for: target.threadID)?.requests[target.requestID],
              request["kind"].string == "user_input" else { return false }
        return request["responseCapability"]["type"].string != "not_resumable"
    }

    func answerQuestion(_ attempt: QuestionResponseAttempt, target: QuestionResponseTarget) async throws {
        guard canAnswerQuestion(target), let connection = connectionID, let socket, let api else { throw ClientError.disconnected }
        let content = attempt.content
        guard content.files.isEmpty || supportsQuestionAttachments else {
            throw ClientError.message("This environment does not support question attachments.")
        }
        if attempt.connection != connection {
            attempt.connection = connection
            attempt.uploaded.removeAll()
        }
        let generation = self.generation
        var attachments: Payload = [:]
        for (question, files) in content.files.sorted(by: { $0.key < $1.key }) {
            var references: [Wire] = []
            for file in files {
                guard connectionID == connection, canAnswerQuestion(target) else { throw ClientError.disconnected }
                if let stored = attempt.uploaded[file.id], stored.isValid {
                    references.append(stored.reference)
                } else {
                    let upload = try await uploadAttachment(file, socket: socket, api: api, generation: generation)
                    attempt.uploaded[file.id] = upload
                    references.append(upload.reference)
                }
            }
            attachments[question] = .array(references)
        }
        guard connectionID == connection, canAnswerQuestion(target) else { throw ClientError.disconnected }
        var fields: Payload = ["commandId": .string(attempt.commandID), "requestId": .string(target.requestID),
                               "answers": .object(content.answers)]
        if !attachments.isEmpty { fields["attachmentsByQuestionId"] = .object(attachments) }
        do { try await dispatch("runtime-request.respond", threadId: target.threadID, fields) }
        catch {
            attempt.uploaded.removeAll()
            throw error
        }
    }

    func editQueuedMessage(_ attempt: QueueEditAttempt, threadID: String, runID: String, connection: UUID) async throws {
        guard canEditQueue(threadID: threadID, connection: connection), let socket, let api else { throw ClientError.disconnected }
        let content = attempt.content
        let generation = self.generation
        let context = presentedDetail(for: threadID)?.queue.state.messages.first { $0.id == runID }?.context ?? .null
        var records = context["records"].array
        var fields: Payload = ["commandId": .string(attempt.commandID), "runId": .string(runID)]
        if let retained = content.retained {
            try PickedAttachment.validate(content.files, retaining: retained)
            var attachments = retained
            records = BrowserAnnotationContext.retaining(records, attachments: retained)
            for file in content.files {
                guard canEditQueue(threadID: threadID, connection: connection) else { throw ClientError.disconnected }
                let reference: Wire
                if let stored = attempt.uploaded[file.id], stored.isValid {
                    reference = stored.reference
                } else {
                    let upload = try await uploadAttachment(file, socket: socket, api: api, generation: generation)
                    attempt.uploaded[file.id] = upload
                    reference = upload.reference
                }
                attachments.append(reference)
                if let annotation = file.browserAnnotation { records += annotation.records(for: reference) }
            }
            fields["attachments"] = .array(attachments)
        }
        let prompt = BrowserAnnotationContext.removingReferences(from: content.text, context: context)
        if let terminalRecords = content.terminalContextRecords {
            records = records.filter { $0["kind"].string != "terminal" } + terminalRecords
        }
        records = TerminalContext.retaining(records, in: prompt)
        guard records.count <= TerminalContext.maximumRecords else {
            throw ClientError.message("A message can contain up to 200 context items.")
        }
        if content.retained != nil || records != context["records"].array {
            if context != .null || !records.isEmpty { fields["context"] = BrowserAnnotationContext.messageContext(records) }
        }
        fields["text"] = .string(BrowserAnnotationContext.addingReferences(to: prompt, records: records))
        guard canEditQueue(threadID: threadID, connection: connection) else { throw ClientError.disconnected }
        try await dispatch("queued-run.edit", threadId: threadID, fields)
    }

    private func uploadAttachment(_ file: PickedAttachment, socket: RPCSocket, api: EnvironmentAPI,
                                  generation: UUID) async throws -> UploadedAttachment {
        let upload = try await socket.request("attachments.createUploadUrl", file.metadata)
        let id = try upload.requireString("attachmentId")
        do { try await api.upload(file, to: upload.requireString("relativeUrl")) }
        catch {
            _ = try? await socket.request("attachments.delete", ["attachmentId": .string(id)])
            throw error
        }
        guard self.socket === socket, generation == self.generation else { throw ClientError.disconnected }
        var reference = file.metadata
        reference["id"] = .string(id)
        return UploadedAttachment(reference: .object(reference), expiresAt: upload["expiresAt"].int ?? 0)
    }

    private func interruptBeforeModelSwitch(threadID: String, runID: String, commandID: String) async throws {
        guard let connection = connectionID else { throw ClientError.disconnected }
        guard data.threads[threadID]?.activeRunId == runID else { return }
        let (stream, ended) = AsyncStream<Void>.makeStream()
        modelSwitchWaiters[threadID] = (runID, connection, ended)
        defer {
            ended.finish()
            if modelSwitchWaiters[threadID]?.connection == connection { modelSwitchWaiters.removeValue(forKey: threadID) }
        }
        // Hold existing follow-ups until the provider has stopped and Continue can start first.
        try await dispatch("run.interrupt", threadId: threadID, [
            "runId": .string(runID), "holdQueue": .bool(true), "commandId": .string("model-switch-interrupt:" + commandID),
        ])
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in stream {} }
            group.addTask { try await Task.sleep(for: .seconds(30)); throw ClientError.timedOut }
            defer { group.cancelAll() }
            try await group.next()
        }
        try Task.checkCancellation()
        guard connectionID == connection, data.threads[threadID]?.archived == false else { throw ClientError.disconnected }
    }

    func send(_ intent: SendIntent) async throws {
        guard let socket, let api, can("orchestration:operate"), !sending.contains(intent.destination) else {
            throw ClientError.disconnected
        }
        if case .project(let id) = intent.destination, let reason = cloneStatus(id)?.sendReason {
            throw ClientError.message(reason)
        }
        if case .thread(let id) = intent.destination,
           (data.threads[id] ?? data.archived[id])?.isProviderNativeSubagent == true {
            throw ClientError.message("Provider-native subagents are read-only.")
        }
        if intent.freshContext {
            guard supportsFreshContext, case .thread = intent.destination else {
                throw ClientError.message("Fresh sessions are unavailable for this conversation.")
            }
        }
        try PickedAttachment.validate(intent.attachments, retaining: intent.retainedAttachments)
        let retainedIDs = intent.retainedAttachments.compactMap { $0["id"].string }
        guard retainedIDs.count == intent.retainedAttachments.count, Set(retainedIDs).count == retainedIDs.count else {
            throw ClientError.message("A saved attachment is invalid or duplicated.")
        }
        let generation = self.generation
        let fileCheckout = draftFileCheckout
        let previous = sendAttempts[intent.destination]
        var attempt = previous.flatMap { $0.intent == intent ? $0 : nil } ?? SendAttempt(intent: intent)
        sendAttempts[intent.destination] = attempt
        sending.insert(intent.destination)
        onChange?(.selection)
        defer {
            if generation == self.generation {
                sending.remove(intent.destination)
                onChange?(.selection)
            }
        }
        if case .interrupt(let runID) = intent.modelSwitch, case .thread(let id) = intent.destination {
            try await interruptBeforeModelSwitch(threadID: id, runID: runID, commandID: attempt.commandId)
        }
        var attachments = intent.retainedAttachments
        var contextRecords = TerminalContext.retaining(
            BrowserAnnotationContext.retaining(intent.retainedContextRecords, attachments: attachments), in: intent.text
        )
        for file in intent.attachments {
            guard self.socket === socket, generation == self.generation else { throw ClientError.disconnected }
            let reference: Wire
            if let stored = attempt.uploaded[file.id], stored.isValid {
                reference = stored.reference
            } else {
                let upload = try await uploadAttachment(file, socket: socket, api: api, generation: generation)
                attempt.uploaded[file.id] = upload
                sendAttempts[intent.destination] = attempt
                reference = upload.reference
            }
            attachments.append(reference)
            if let annotation = file.browserAnnotation { contextRecords += annotation.records(for: reference) }
        }
        guard contextRecords.count <= TerminalContext.maximumRecords else {
            throw ClientError.message("A message can contain up to 200 context items.")
        }
        let messageContext = contextRecords.isEmpty ? nil : BrowserAnnotationContext.messageContext(contextRecords)
        let text = BrowserAnnotationContext.addingReferences(to: intent.text, records: contextRecords)
        guard self.socket === socket, generation == self.generation else { throw ClientError.disconnected }
        switch intent.destination {
        case .project(let projectId):
            if let reason = cloneStatus(projectId)?.sendReason { throw ClientError.message(reason) }
            guard let project = data.projects[projectId], !project.archived else {
                throw ClientError.message("Choose an active project to start a thread.")
            }
            if attempt.checkout == nil {
                var checkout = intent.checkout ?? .root()
                if intent.checkout == nil {
                    var fileMode: ProjectCheckoutMode?
                    if !isScratch(project), projectPreferences.configuredCheckout(for: project) == nil,
                       let scope = projectFileScope(projectId) {
                        if let fileCheckout, fileCheckout.scope == scope { fileMode = await fileCheckout.task.value }
                        else { fileMode = (try? await readProjectFile(scope))?.checkout }
                    }
                    try Task.checkCancellation()
                    guard self.socket === socket, generation == self.generation else { throw ClientError.disconnected }
                    checkout = defaultCheckout(for: project, fileMode: fileMode)
                    if case .newWorktree = checkout {
                        let refs = try await request("vcs.listRefs", ["cwd": .string(project.root), "limit": .int(1)])
                        if refs["isRepo"].bool == false { checkout = .root() }
                    }
                }
                guard self.socket === socket, generation == self.generation, let current = data.projects[projectId],
                      !current.archived, current.root == project.root else { throw ClientError.disconnected }
                attempt.checkout = checkout
                sendAttempts[intent.destination] = attempt
            }
            guard let checkout = attempt.checkout else { throw ClientError.invalidResponse }
            let title = String(intent.text.split(whereSeparator: \.isNewline).first?.prefix(100) ?? "New thread")
            var message: Payload = ["messageId": .string(attempt.messageId), "text": .string(text), "attachments": .array(attachments)]
            message["context"] = messageContext
            let response = try await request("orchestration.launchThread", [
                "commandId": .string(attempt.commandId), "threadId": .string(attempt.threadId),
                "projectId": .string(projectId), "title": .string(title), "generateTitle": .bool(true),
                "creationSource": .string("web"), "modelSelection": intent.model,
                "runtimeMode": .string(intent.runtimeMode), "interactionMode": .string(intent.interactionMode),
                "workspaceStrategy": checkout.strategy,
                "initialMessage": .object(message),
            ])
            let id = try response.requireString("threadId")
            if generation == self.generation {
                if let explicit = intent.checkout, let environmentID = environment?.id,
                   draftCheckouts[environmentID]?[projectId] == DraftCheckout(checkout: explicit, threadID: intent.preparedThreadID) {
                    draftCheckouts[environmentID]?.removeValue(forKey: projectId)
                }
                if selection == intent.destination { select(.thread(id)) }
            }
        case .thread(let id):
            let thread = data.threads[id]
            let dispatchMode: Wire
            if case .restart(let runID) = intent.modelSwitch {
                dispatchMode = .object(["type": .string("restart_active"), "targetRunId": .string(runID)])
            } else {
                let queue = intent.modelSwitch == nil && thread?.isWorking == true
                dispatchMode = .object(["type": .string(queue ? "queue_after_active" : "start_immediately")])
            }
            var fields: Payload = [
                "commandId": .string(attempt.commandId), "messageId": .string(attempt.messageId),
                "createdBy": .string("user"), "creationSource": .string("web"),
                "text": .string(text), "attachments": .array(attachments),
                "modelSelection": intent.model,
                "dispatchMode": dispatchMode,
            ]
            if intent.freshContext { fields["freshContext"] = .bool(true) }
            fields["context"] = messageContext
            if let delivery = intent.deliveryIntent { fields["deliveryIntent"] = .string(delivery) }
            if thread?.isSideChat == true, thread?.latestRunID == nil,
               let title = intent.text.split(whereSeparator: \.isNewline).first?.prefix(100), !title.isEmpty {
                fields["titleSeed"] = .string(String(title))
            }
            try await dispatch("message.dispatch", threadId: id, fields)
        }
        if generation == self.generation { sendAttempts.removeValue(forKey: intent.destination) }
    }
}
