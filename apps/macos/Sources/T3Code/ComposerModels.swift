import Foundation

enum ComposerProvider: String, CaseIterable {
    case claude = "claudeAgent"
    case codex

    var title: String { self == .claude ? "Claude" : "Codex" }

    func modelTitle(_ name: String) -> String {
        guard self == .claude, name.lowercased().hasPrefix("claude ") else { return name }
        return String(name.dropFirst("Claude ".count))
    }
}

struct ComposerModels {
    struct Choice: Equatable {
        let title: String
        let instanceTitle: String?
        let selection: Wire
        let familyTitle: String
        let version: String?

        var pickerTitle: String {
            guard let version, !title.localizedCaseInsensitiveContains(version) else { return title }
            return "\(familyTitle) \(version)"
        }
    }

    struct Group: Equatable {
        let key: GroupKey
        let title: String
        let instanceTitle: String?
        var choices: [Choice]
    }

    struct GroupKey: Hashable {
        let instanceID: String?
        let family: String
        let unversionedSlug: String?
    }

    let providers: [Provider]

    func provider(for selection: Wire) -> Provider? {
        providers.first { $0.id == Self.instanceID(selection) }
    }

    func family(for selection: Wire) -> ComposerProvider? {
        let driver = provider(for: selection)?.driver ?? Self.instanceID(selection)
        return driver.flatMap(ComposerProvider.init(rawValue:))
    }

    func options(for selection: Wire) -> ComposerModelOptions {
        let model = provider(for: selection).flatMap { self.model(in: $0, for: selection) }
        return ComposerModelOptions(selection: selection, descriptors: model?.options ?? [])
    }

    func modelSwitch(from active: Wire, to selected: Wire) -> (activeTitle: String, selectedTitle: String)? {
        guard Self.isSelection(active), Self.isSelection(selected),
              let target = provider(for: selected), target.isAvailable,
              let activeSlug = active["model"].string, let selectedSlug = selected["model"].string else { return nil }
        let current = provider(for: active).flatMap { model(in: $0, for: active) }
        let next = model(in: target, for: selected)
        guard Self.instanceID(active) != target.id || (current?.slug ?? activeSlug) != (next?.slug ?? selectedSlug) else {
            return nil
        }
        return (choice(model: current, family: family(for: active), instanceTitle: nil, selection: active, fallback: activeSlug).title,
                choice(model: next, family: family(for: selected), instanceTitle: nil, selection: selected, fallback: selectedSlug).title)
    }

    func usageLimitPreview(for selection: Wire, sources: [UsageLimitSource]) -> UsageLimitPreview? {
        guard let provider = provider(for: selection) else { return nil }
        let model = model(in: provider, for: selection)
        let slug = selection["model"].string
        let title = slug.map { choice(model: model, family: family(for: selection), instanceTitle: nil,
                                      selection: selection, fallback: $0).title }
        let account: UsageLimitAccount?
        if let direct = provider.usageLimit, !direct.windows.isEmpty {
            account = direct
        } else {
            account = matchingHubAccount(for: provider, sources: sources) ?? provider.usageLimit
        }
        let names = [slug, model?.slug, model?.name].compactMap { $0 } + (model?.aliases ?? [])
        return UsageLimitPreview(provider: provider.name, model: title, account: account,
                                 windows: account?.previewWindows(modelNames: names) ?? [])
    }

    func usageLimitAccounts(sources: [UsageLimitSource]) -> [UsageLimitAccount] {
        let native = providers.compactMap { provider -> UsageLimitAccount? in
            guard let account = provider.usageLimit else { return nil }
            if account.windows.isEmpty, account.externalUsage == nil, (account.resetCredits ?? 0) == 0,
               matchingHubAccount(for: provider, sources: sources) != nil { return nil }
            return account
        }
        return native + sources.flatMap(\.accounts)
    }

    private func matchingHubAccount(for provider: Provider, sources: [UsageLimitSource]) -> UsageLimitAccount? {
        guard !sources.isEmpty, let identity = provider.usageIdentity else { return nil }
        let driver = UsageLimitAccount.normalizedDriver(provider.driver)
        let candidates = sources.flatMap(\.accounts).filter { $0.driver == driver && $0.identity?.email == identity.email }
        guard !candidates.isEmpty else { return nil }
        let nativeWorkspaces = providers.lazy.filter {
            $0.enabled && UsageLimitAccount.normalizedDriver($0.driver) == driver && $0.usageIdentity?.email == identity.email
        }.compactMap { $0.usageIdentity?.workspaceID }
        var knownWorkspaces = Set(candidates.compactMap { $0.identity?.workspaceID }).union(nativeWorkspaces)
        if let workspace = identity.workspaceID { knownWorkspaces.insert(workspace) }
        if identity.workspaceID == nil && knownWorkspaces.count > 1 { return nil }
        let workspace = identity.workspaceID ?? knownWorkspaces.first
        return candidates.filter { account in
            let candidate = account.identity?.workspaceID
            return !account.windows.isEmpty && (candidate == workspace || (candidate == nil && knownWorkspaces.count <= 1))
        }.max { ($0.checkedAt ?? .distantPast) < ($1.checkedAt ?? .distantPast) }
    }

    func isAvailable(_ family: ComposerProvider) -> Bool {
        availableProviders.contains { $0.driver == family.rawValue }
    }

    func initialSelection(draft: Wire, fallback: Wire, existingThread: Bool) -> Wire {
        if Self.isSelection(draft) { return draft }
        if Self.isSelection(fallback), existingThread || family(for: fallback) != nil { return fallback }
        return availableProviders.first.map(defaultSelection(for:)) ?? .null
    }

    func defaultSelection(for family: ComposerProvider, preferred: Wire) -> Wire {
        let matching = availableProviders.filter { $0.driver == family.rawValue }
        if let provider = matching.first(where: { $0.id == Self.instanceID(preferred) }) {
            if model(in: provider, for: preferred) != nil { return preferred }
            return defaultSelection(for: provider)
        }
        return matching.first.map(defaultSelection(for:)) ?? .null
    }

    func choices(preserving selection: Wire) -> [Choice] {
        let family = family(for: selection)
        let matching = availableProviders.filter { $0.driver == family?.rawValue }
        let selectedProvider = provider(for: selection)
        let listedProviders = matching + (selectedProvider.map { selected in
            matching.contains { $0.id == selected.id } ? [] : [selected]
        } ?? [])
        let names = Dictionary(grouping: listedProviders, by: \.name)
        let selectedSlug = selectedProvider.flatMap { model(in: $0, for: selection)?.slug }
        func instanceTitle(_ provider: Provider) -> String? {
            guard listedProviders.count > 1 else { return nil }
            return (names[provider.name]?.count ?? 0) > 1 ? "\(provider.name) · \(provider.id)" : provider.name
        }
        var choices = matching.flatMap { provider in
            provider.models.sorted { $0.isDefault && !$1.isDefault }.map { model in
                let value = provider.id == selectedProvider?.id && model.slug == selectedSlug ? selection : provider.selection(model)
                return choice(model: model, family: family, instanceTitle: instanceTitle(provider), selection: value)
            }
        }
        if Self.isSelection(selection), !choices.contains(where: { $0.selection == selection }) {
            let slug = selection["model"].string ?? ""
            let model = selectedProvider.flatMap { self.model(in: $0, for: selection) }
            choices.append(choice(model: model, family: family,
                                  instanceTitle: selectedProvider.flatMap(instanceTitle), selection: selection, fallback: slug))
        }
        return choices
    }

    func groups(preserving selection: Wire) -> [Group] {
        var positions: [GroupKey: Int] = [:]
        var groups: [Group] = []
        for choice in choices(preserving: selection) {
            let key = GroupKey(instanceID: Self.instanceID(choice.selection), family: choice.familyTitle,
                               unversionedSlug: choice.version == nil ? choice.selection["model"].string : nil)
            if let index = positions[key] {
                groups[index].choices.append(choice)
            } else {
                positions[key] = groups.count
                groups.append(Group(key: key, title: choice.familyTitle, instanceTitle: choice.instanceTitle, choices: [choice]))
            }
        }
        guard family(for: selection) == .claude else { return groups }
        let fable = groups.filter { $0.title.caseInsensitiveCompare("Fable") == .orderedSame }
        return fable + groups.filter { $0.title.caseInsensitiveCompare("Fable") != .orderedSame }
    }

    func pickerTitle(for selection: Wire) -> String? {
        guard let slug = selection["model"].string else { return nil }
        let model = provider(for: selection).flatMap { self.model(in: $0, for: selection) }
        return choice(model: model, family: family(for: selection), instanceTitle: nil, selection: selection, fallback: slug).pickerTitle
    }

    private func model(in provider: Provider, for selection: Wire) -> ProviderModel? {
        guard let slug = selection["model"].string else { return nil }
        return provider.models.first { $0.slug == slug } ?? provider.models.first {
            $0.aliases.contains { $0.caseInsensitiveCompare(slug) == .orderedSame }
        }
    }

    private func choice(model: ProviderModel?, family: ComposerProvider?, instanceTitle: String?,
                        selection: Wire, fallback: String = "") -> Choice {
        let name = model?.name ?? fallback
        let title = model?.isCustom == true ? name : family?.modelTitle(name) ?? name
        let parts = model?.isCustom == true ? nil : Self.versionParts(model?.slug ?? fallback, provider: family)
        return Choice(title: title, instanceTitle: instanceTitle, selection: selection,
                      familyTitle: parts?.family ?? title, version: parts?.version)
    }

    private static func versionParts(_ slug: String, provider: ComposerProvider?) -> (family: String, version: String)? {
        let raw = slug.lowercased()
        let identifier = raw.hasPrefix("openai.") ? String(raw.dropFirst("openai.".count)) : raw
        let bracket = identifier.split(separator: "[", maxSplits: 1, omittingEmptySubsequences: false)
        let tokens = (bracket.first ?? "").split(separator: "-")
        let context = bracket.count == 2 ? " [" + bracket[1] : ""
        switch provider {
        case .claude:
            guard tokens.first == "claude", let start = tokens.indices.dropFirst(2).first(where: {
                isVersion(tokens[$0])
            }) else { return nil }
            let name = tokens[1..<start].joined(separator: " ").capitalized
            var version = String(tokens[start])
            var suffix = start + 1
            if !version.contains("."), tokens.indices.contains(suffix), tokens[suffix].count <= 2,
               isInteger(tokens[suffix]) {
                version += "." + tokens[suffix]
                suffix += 1
            }
            if suffix < tokens.count { version += " " + tokens[suffix...].joined(separator: "-") }
            return (name, version + context)
        case .codex:
            guard tokens.first == "gpt", tokens.count >= 2, isVersion(tokens[1]) else { return nil }
            let variant = tokens.dropFirst(2).joined(separator: " ").capitalized
            return (variant.isEmpty ? "GPT" : "GPT " + variant, String(tokens[1]) + context)
        case nil:
            return nil
        }
    }

    private static func isVersion(_ token: Substring) -> Bool {
        token.split(separator: ".", omittingEmptySubsequences: false).allSatisfy(isInteger) && !token.isEmpty
    }

    private static func isInteger(_ token: Substring) -> Bool {
        !token.isEmpty && token.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private var availableProviders: [Provider] {
        providers.filter { $0.isAvailable && !$0.models.isEmpty && ComposerProvider(rawValue: $0.driver) != nil }
    }

    private func defaultSelection(for provider: Provider) -> Wire {
        (provider.models.first(where: \.isDefault) ?? provider.models.first).map(provider.selection) ?? .null
    }

    static func instanceID(_ selection: Wire) -> String? {
        selection["instanceId"].string ?? selection["provider"].string
    }

    static func isSelection(_ selection: Wire) -> Bool {
        instanceID(selection)?.isEmpty == false && selection["model"].string?.isEmpty == false
    }
}
