import AppKit

@MainActor
final class ProviderSetupPanel: NSView {
    private struct InteractionKey: Equatable {
        let flow: String
        let interaction: String?
    }

    private struct SignInPage {
        let url: URL
        let needsConsent: Bool
        let callback: CodexAuthorizationRequest?
        let deviceCode: String?
    }

    private let workspace: Workspace
    private let runtime = label(size: 12, color: WorkspaceStyle.secondary)
    private let executable = label(size: 11, color: WorkspaceStyle.muted)
    private let progress = NSProgressIndicator()
    private let account = label(size: 12, color: WorkspaceStyle.secondary)
    private let methods = NSPopUpButton()
    private let credentials = NSStackView()
    private let callbackField = NSSecureTextField()
    private let deviceCode = label(size: 13, weight: .semibold, color: WorkspaceStyle.ink)
    private let terminal = ProviderSignInTerminal()
    private let message = NSTextField(wrappingLabelWithString: "")
    private lazy var install = button("Install Runtime") { [weak self] in self?.perform(.install) }
    private lazy var cancelInstall = button("Cancel Install") { [weak self] in
        if let self, let id = installation?.operationID { perform(.cancelInstall(id)) }
    }
    private lazy var removeInstall = button("Remove Runtime…") { [weak self] in
        self?.confirm(.removeInstall, title: "Remove downloaded runtime?", message: "T3 Code removes the managed binary from this environment.")
    }
    private lazy var updateCLI = button("Update CLI") { [weak self] in
        if let self, let version = provider?.management.updateVersion { perform(.updateCLI(version)) }
    }
    private lazy var signIn = button("Start Sign-In") { [weak self] in self?.startSignIn() }
    private lazy var cancelSignIn = button("Cancel Sign-In") { [weak self] in
        if let self, let flow = authentication?.flowID {
            callbackTask?.cancel()
            callbackTask = nil
            perform(.cancelSignIn(flow))
        }
    }
    private lazy var signOut = button("Sign Out…") { [weak self] in
        self?.confirm(.signOut, title: "Sign out of this provider?", message: "T3 Code stops its active sessions on this environment.")
    }
    private lazy var removeMethod = button("Remove Saved Sign-In…") { [weak self] in
        guard let self, let method = selectedMethod, method.canRemove else { return }
        confirm(.removeMethod(method.id), title: "Remove this saved sign-in?", message: "You can add the account again by signing in.")
    }
    private lazy var openPage = button("Open Sign-In Page") { [weak self] in self?.usePage(copy: false) }
    private lazy var copyPage = button("Copy Link") { [weak self] in self?.usePage(copy: true) }
    private lazy var copyCode = button("Copy Code") { [weak self] in
        if let self, let code = signInPage?.deviceCode { copy(code) }
    }
    private lazy var complete = button("Finish Sign-In") { [weak self] in self?.completeFromField() }
    private lazy var submitCredentials = button("Submit Credentials") { [weak self] in self?.sendCredentials() }
    private lazy var pageControls = row([openPage, copyPage, NSView(), deviceCode, copyCode])
    private lazy var callbackControls = row([callbackField, complete])

    private var provider: Provider?
    private var target: ProviderSetupTarget?
    private var isPresented = false
    private var installation: ProviderInstallState?
    private var authentication: ProviderAuthState?
    private var installRevision = 0
    private var authRevision = 0
    private var installStream: Task<Void, Never>?
    private var authStream: Task<Void, Never>?
    private var callbackTask: Task<Void, Never>?
    private var terminalTask: Task<Void, Never>?
    private var terminalReplies: [ProviderAuthReply] = []
    private var operationID: UUID?
    private var installProblem: String?
    private var authProblem: String?
    private var failure: String?
    private var interactionKey: InteractionKey?
    private var methodList: [ProviderAuthMethod] = []
    private var credentialFields: [(ProviderAuthField, NSTextField)] = []
    private var lastBusy = false
    var onBusyChange: (() -> Void)?
    var openExternal: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(frame: .zero)
        progress.style = .bar
        progress.isIndeterminate = false
        progress.maxValue = 1
        progress.controlSize = .small
        progress.setAccessibilityLabel("Provider Install Progress")
        credentials.orientation = .vertical
        credentials.alignment = .leading
        credentials.spacing = 7
        callbackField.placeholderString = "Paste the redirect URL"
        callbackField.setAccessibilityLabel("Sign-In Redirect URL")
        methods.isBordered = false
        methods.setAccessibilityLabel("Provider Sign-In Method")
        methods.target = self
        methods.action = #selector(changeMethod)
        message.font = .systemFont(ofSize: 11.5)
        message.maximumNumberOfLines = 3
        terminal.onReply = { [weak self] reply in self?.enqueueTerminal(reply) }

        let runtimeRow = row([label("Runtime", size: 12.5, weight: .semibold), runtime, NSView(), install, cancelInstall, removeInstall, updateCLI], spacing: 7)
        let accountRow = row([label("Account", size: 12.5, weight: .semibold), account, NSView(), cancelSignIn], spacing: 7)
        let accountActions = row([methods, signIn, removeMethod, signOut, NSView()], spacing: 7)
        let divider = Surface(WorkspaceStyle.outline)
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let body = column([runtimeRow, executable, progress, divider, accountRow, accountActions, pageControls,
                           callbackControls, credentials, terminal, message], spacing: 8, alignment: .width)
        let card = Surface(WorkspaceStyle.composer, border: WorkspaceStyle.outline, radius: 10)
        fill(body, in: card, inset: 12)
        fill(card, in: self)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var active: Bool {
        installation?.active == true || authentication?.active == true || provider?.management.updating == true || operationID != nil
    }

    func sync(provider: Provider?, target: ProviderSetupTarget?, presented: Bool) {
        if self.target != target {
            stopStreams()
            callbackTask?.cancel()
            callbackTask = nil
            operationID = nil
            installation = nil
            authentication = nil
            failure = nil
            installProblem = nil
            authProblem = nil
            resetInteraction(nil)
        }
        self.provider = provider
        self.target = target
        isPresented = presented
        if !presented {
            stopStreams()
            clearInputs()
            callbackField.stringValue = ""
            for (field, input) in credentialFields where field.secret { input.stringValue = "" }
        } else {
            startStreams()
        }
        render()
    }

    func reloadStreams() {
        stopStreams()
        installProblem = nil
        authProblem = nil
        failure = nil
        startStreams()
        render()
    }

    private var canManage: Bool { target != nil && workspace.can("providers:manage") }

    private func startStreams() {
        guard isPresented, let target, let provider else { return }
        if provider.management.canInstall, installStream == nil, installProblem == nil {
            installStream = Task { [weak self, workspace] in
                do {
                    try await workspace.subscribeProviderSetup(target, .installation) { frames in
                        guard let self, self.target == target, !Task.isCancelled else { return }
                        for frame in frames {
                            if let next = ProviderInstallState(frame) { self.installation = next; self.installRevision += 1 }
                        }
                        self.render()
                    }
                } catch {
                    guard let self, self.target == target, !Task.isCancelled else { return }
                    self.installProblem = error.localizedDescription
                    self.render()
                }
            }
        }
        if provider.management.canAuthenticate, canManage, authStream == nil, authProblem == nil {
            authStream = Task { [weak self, workspace] in
                do {
                    try await workspace.subscribeProviderSetup(target, .authentication) { frames in
                        guard let self, self.target == target, !Task.isCancelled else { return }
                        for frame in frames {
                            if let next = ProviderAuthState(frame) { self.authRevision += 1; self.acceptAuth(next) }
                        }
                        self.render()
                    }
                } catch {
                    guard let self, self.target == target, !Task.isCancelled else { return }
                    self.authProblem = error.localizedDescription
                    self.render()
                }
            }
        }
    }

    private func stopStreams() {
        installStream?.cancel()
        authStream?.cancel()
        installStream = nil
        authStream = nil
    }

    private func acceptAuth(_ next: ProviderAuthState) {
        guard next.instanceID == target?.instanceID else { return }
        let previous = authentication
        authentication = next
        let key = next.active ? next.flowID.map { InteractionKey(flow: $0, interaction: next.interaction?.id) } : nil
        if interactionKey != key {
            if next.flowID != previous?.flowID || !next.active { callbackTask?.cancel(); callbackTask = nil }
            resetInteraction(key)
        }
        if next.phase == .succeeded, previous?.phase != .succeeded, let target {
            Task { [workspace] in
                guard workspace.providerSetupTarget(target.instanceID) == target else { return }
                _ = try? await workspace.request("server.refreshProviders", ["instanceId": .string(target.instanceID)])
            }
        }
    }

    private func resetInteraction(_ key: InteractionKey?) {
        interactionKey = key
        callbackField.stringValue = ""
        for view in credentials.arrangedSubviews { credentials.removeArrangedSubview(view); view.removeFromSuperview() }
        credentialFields = []
        clearInputs()
        terminal.reset()
    }

    private func clearInputs() {
        terminalReplies.removeAll()
        terminalTask?.cancel()
        terminalTask = nil
    }

    private var selectedMethod: ProviderAuthMethod? {
        guard let id = methods.selectedItem?.representedObject as? String else { return nil }
        return methodList.first { $0.id == id }
    }

    @objc private func changeMethod() { render() }

    private var signInPage: SignInPage? {
        guard let authentication, authentication.active, authentication.flowID != nil else { return nil }
        let raw: String
        let consent: Bool
        let wantsCallback: Bool
        let code: String?
        switch authentication.interaction?.content {
        case .browser(let url, let requiresConsent, let callback): (raw, consent, wantsCallback, code) = (url, requiresConsent, callback, nil)
        case .device(let url, let value): (raw, consent, wantsCallback, code) = (url, false, false, value)
        case nil:
            guard let url = authentication.authorizationURL else { return nil }
            (raw, consent, wantsCallback, code) = (url, false, provider?.driver == ComposerProvider.codex.rawValue, nil)
        default: return nil
        }
        guard let url = ProviderBrowserAddress.url(raw) else { return nil }
        let callback = wantsCallback ? CodexAuthorizationRequest(raw) : nil
        guard !wantsCallback || callback != nil else { return nil }
        return .init(url: url, needsConsent: consent, callback: callback, deviceCode: code)
    }

    private func render() {
        defer {
            if lastBusy != active { lastBusy = active; onBusyChange?() }
        }
        guard let provider else { isHidden = true; return }
        isHidden = false
        let state = provider.management
        let installing = installation?.active == true
        let signingIn = authentication?.active == true
        let installed = installation?.installedVersion != nil || state.installed == true
        let signedIn = state.authStatus == "authenticated" || authentication?.phase == .succeeded
        let editable = canManage && operationID == nil && isPresented
        runtime.stringValue = runtimeDescription(state: state, installed: installed)
        let runtimePath = installation?.executable ?? state.shadowHomePath ?? state.homePath
        executable.stringValue = runtimePath ?? ""
        executable.toolTip = runtimePath
        executable.isHidden = executable.stringValue.isEmpty
        progress.isHidden = installation?.phase != .downloading || installation?.fraction == nil
        progress.doubleValue = installation?.fraction ?? 0
        install.title = installation?.updateAvailable == true ? "Update Runtime" :
            installation?.phase == .failed || installation?.phase == .cancelled ? "Retry Install" : installed ? "Reinstall Runtime" : "Install Runtime"
        install.setAccessibilityLabel(install.title)
        install.isHidden = !state.canInstall || installing || installation?.source == "local"
        install.isEnabled = editable && provider.enabled && installation != nil && !signingIn
        cancelInstall.isHidden = !installing || installation?.operationID == nil
        cancelInstall.isEnabled = editable
        removeInstall.isHidden = installation?.canRemove != true || installing
        removeInstall.isEnabled = editable && !signingIn
        updateCLI.isHidden = state.canInstall || state.updateVersion == nil || state.updating
        updateCLI.isEnabled = editable && !signingIn
        account.stringValue = signingIn ? authentication?.message ?? "Sign-in in progress…" : signedIn ?
            state.authLabel.map { "Signed in · \($0)" } ?? "Signed in" : state.authStatus == "unauthenticated" ? "Signed out" : "Not checked"
        updateMethods(authentication?.methods ?? [])
        methods.isHidden = !state.canAuthenticate || signingIn || methodList.isEmpty
        methods.isEnabled = editable
        signIn.title = signedIn ? "Sign In Again" : "Start Sign-In"
        signIn.setAccessibilityLabel(signIn.title)
        signIn.isHidden = !state.canAuthenticate || signingIn
        signIn.isEnabled = editable && provider.enabled && installed && authentication != nil && !installing
        cancelSignIn.isHidden = !signingIn || authentication?.flowID == nil
        cancelSignIn.isEnabled = editable
        signOut.isHidden = signingIn || !signedIn || !state.canLogout
        signOut.isEnabled = editable && !installing
        removeMethod.isHidden = signingIn || selectedMethod?.canRemove != true
        removeMethod.isEnabled = editable && !installing
        let page = signInPage
        let invalidPage = signingIn && page == nil && (authentication?.authorizationURL != nil || {
            if case .browser = authentication?.interaction?.content { return true }
            if case .device = authentication?.interaction?.content { return true }
            return false
        }())
        pageControls.isHidden = page == nil
        openPage.isEnabled = editable && callbackTask == nil
        copyPage.isEnabled = editable
        deviceCode.stringValue = page?.deviceCode ?? ""
        deviceCode.isHidden = page?.deviceCode == nil
        copyCode.isHidden = deviceCode.isHidden
        copyCode.isEnabled = editable
        callbackControls.isHidden = page?.callback == nil
        complete.isEnabled = editable
        callbackField.isEnabled = editable
        updateInteraction(editable: editable)
        let note = failure ?? authProblem ?? installProblem ?? (invalidPage ? "The environment returned an invalid sign-in page." : nil) ??
            (authentication?.phase == .failed ? authentication?.message : nil) ??
            (installation?.phase == .failed ? installation?.message : nil) ?? (state.updateStatus == "failed" ? state.updateMessage : nil)
        message.stringValue = note ?? (operationID == nil ? "" : "Working…")
        message.textColor = note == nil ? WorkspaceStyle.secondary : WorkspaceStyle.negative
        message.isHidden = message.stringValue.isEmpty
    }

    private func runtimeDescription(state: ProviderManagement, installed: Bool) -> String {
        if state.updating { return state.updateMessage ?? "Updating CLI…" }
        switch installation?.phase {
        case .downloading:
            let bytes = ByteCountFormatter.string(fromByteCount: Int64(installation?.downloaded ?? 0), countStyle: .file)
            return installation?.total.map { "Downloading \(bytes) of \(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))" } ?? "Downloading \(bytes)"
        case .extracting: return "Extracting runtime…"
        case .verifying: return "Verifying runtime…"
        default:
            let version = installation?.installedVersion ?? state.version
            if installed { return version.map { "Installed · \($0)" } ?? "Installed" }
            return state.installed == false ? "Not installed" : "Not checked"
        }
    }

    private func updateMethods(_ next: [ProviderAuthMethod]) {
        guard next != methodList else { return }
        let id = selectedMethod?.id
        methodList = next
        methods.removeAllItems()
        for method in next {
            let item = NSMenuItem(title: method.name, action: nil, keyEquivalent: "")
            item.representedObject = method.id
            methods.menu?.addItem(item)
        }
        if let index = next.firstIndex(where: { $0.id == id }) { methods.selectItem(at: index) }
        else if !next.isEmpty { methods.selectItem(at: 0) }
    }

    private func updateInteraction(editable: Bool) {
        guard authentication?.active == true, authentication?.flowID != nil else {
            credentials.isHidden = true
            terminal.isHidden = true
            return
        }
        switch authentication?.interaction?.content {
        case .credentials(let fields):
            terminal.isHidden = true
            credentials.isHidden = false
            if credentialFields.map(\.0) != fields {
                for view in credentials.arrangedSubviews { credentials.removeArrangedSubview(view); view.removeFromSuperview() }
                credentialFields = fields.map { field in
                    let input: NSTextField = field.secret ? NSSecureTextField() : NSTextField()
                    input.setAccessibilityLabel(field.label)
                    input.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
                    let title = label(field.label, size: 11.5, color: WorkspaceStyle.secondary)
                    credentials.addArrangedSubview(row([title, input]))
                    return (field, input)
                }
                credentials.addArrangedSubview(submitCredentials)
            }
            for (_, field) in credentialFields { field.isEnabled = editable }
            submitCredentials.isEnabled = editable
        case .terminal(let output, let offset):
            credentials.isHidden = true
            terminal.isHidden = false
            terminal.render(output: output, offset: offset)
        default:
            credentials.isHidden = true
            terminal.isHidden = true
        }
    }

    private func startSignIn() {
        let managedCodex = provider?.driver == ComposerProvider.codex.rawValue && provider?.management.canAuthenticate == true
        perform(.signIn(method: selectedMethod?.id, clientCallback: managedCodex))
    }

    private func usePage(copy link: Bool) {
        guard let page = signInPage, let target, let flow = authentication?.flowID, canManage else { return }
        let open = { [weak self] in
            guard let self, self.target == target, self.authentication?.flowID == flow else { return }
            if link { self.copy(page.url.absoluteString) }
            else if let callback = page.callback { self.receiveCallback(callback, target: target, flow: flow) }
            else if !self.openExternal(page.url) { self.failure = "Could not open the sign-in page."; self.render() }
        }
        if page.needsConsent, let interaction = authentication?.interaction?.id {
            perform(.respond(flow: flow, interaction: interaction, reply: .acceptBrowser), completed: open)
        } else { open() }
    }

    private func receiveCallback(_ request: CodexAuthorizationRequest, target: ProviderSetupTarget, flow: String) {
        guard callbackTask == nil else { return }
        failure = nil
        callbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                let callback = try await ProviderAuthCallbackListener(request: request).receive(openPage: openExternal)
                guard !Task.isCancelled, self.target == target, authentication?.flowID == flow else { return }
                callbackTask = nil
                perform(.complete(flow: flow, callback: callback))
            } catch {
                guard !Task.isCancelled, self.target == target else { return }
                callbackTask = nil
                failure = error.localizedDescription
                render()
            }
        }
        render()
    }

    private func completeFromField() {
        guard let request = signInPage?.callback, let flow = authentication?.flowID else { return }
        do {
            let callback = try request.callback(callbackField.stringValue)
            callbackField.stringValue = ""
            callbackTask?.cancel()
            callbackTask = nil
            perform(.complete(flow: flow, callback: callback))
        } catch { failure = error.localizedDescription; render() }
    }

    private func sendCredentials() {
        guard let flow = authentication?.flowID, let interaction = authentication?.interaction?.id else { return }
        var values: [String: String] = [:]
        for (field, input) in credentialFields {
            guard !input.stringValue.isEmpty, input.stringValue.utf16.count <= 16_384 else {
                failure = "Enter a value for \(field.label)."
                render()
                return
            }
            values[field.name] = input.stringValue
        }
        for (field, input) in credentialFields where field.secret { input.stringValue = "" }
        perform(.respond(flow: flow, interaction: interaction, reply: .credentials(values)))
    }

    private func enqueueTerminal(_ reply: ProviderAuthReply) {
        guard canManage, isPresented, let target, let flow = authentication?.flowID, let interaction = authentication?.interaction,
              case .terminal = interaction.content, terminalReplies.count < 64 else { return }
        terminalReplies.append(reply)
        guard terminalTask == nil else { return }
        terminalTask = Task { [weak self, workspace] in
            guard let self else { return }
            while !Task.isCancelled, self.target == target, authentication?.flowID == flow, authentication?.interaction?.id == interaction.id,
                  !terminalReplies.isEmpty {
                let next = terminalReplies.removeFirst()
                do { _ = try await workspace.providerSetup(target, .respond(flow: flow, interaction: interaction.id, reply: next)) }
                catch {
                    if !Task.isCancelled { failure = error.localizedDescription; terminalReplies.removeAll(); render() }
                    break
                }
            }
            if !Task.isCancelled { terminalTask = nil }
        }
    }

    private func perform(_ command: ProviderSetupCommand, completed: (() -> Void)? = nil) {
        guard canManage, operationID == nil, let target else { return }
        let id = UUID()
        let installRevision = self.installRevision
        let authRevision = self.authRevision
        operationID = id
        failure = nil
        Task { [weak self, workspace] in
            do {
                let result = try await workspace.providerSetup(target, command)
                guard let self, self.operationID == id, self.target == target else { return }
                if let next = ProviderInstallState(result), self.installRevision == installRevision { installation = next }
                if let next = ProviderAuthState(result), self.authRevision == authRevision { acceptAuth(next) }
                self.operationID = nil
                render()
                completed?()
            } catch {
                guard let self, self.operationID == id, self.target == target else { return }
                self.operationID = nil
                failure = error.localizedDescription
                render()
            }
        }
        render()
    }

    private func confirm(_ command: ProviderSetupCommand, title: String, message: String) {
        guard canManage, operationID == nil, let target, let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Cancel")
        let action: String = if case .signOut = command { "Sign Out" } else { "Remove" }
        alert.addButton(withTitle: action).hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn, self?.target == target { self?.perform(command) }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> ActionButton {
        ActionButton(title, style: .subtle, action: action)
    }
}
