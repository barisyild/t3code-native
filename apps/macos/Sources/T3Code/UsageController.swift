import AppKit

@MainActor
final class UsageController: NSViewController {
    private enum Metric: Int {
        case cost, tokens, limits

        var heading: String { self == .cost ? "Estimated cost" : "Tokens used" }

        func amount(_ totals: UsageTotals) -> Double { self == .cost ? totals.cost : totals.tokens }

        func format(_ amount: Double) -> String {
            if self == .cost {
                return amount.formatted(.currency(code: "USD").precision(.fractionLength(2...4)))
            }
            return amount.formatted(.number.precision(.fractionLength(0)))
        }
    }

    private let workspace: Workspace
    private let environment = label(size: 11.5, color: WorkspaceStyle.muted)
    private let metrics = NSSegmentedControl()
    private let periodMenu = NSPopUpButton()
    private let providerMenu = NSPopUpButton()
    private let document = UsageDocument()
    private lazy var scroll = scroller(for: document)
    private lazy var back = ActionButton("Back to Workspace", symbol: "chevron.left", iconOnly: true, style: .subtle) { [weak self] in
        self?.onBack?()
    }
    private lazy var refresh = ActionButton("Refresh Usage", symbol: "arrow.clockwise", iconOnly: true, style: .subtle) { [weak self] in
        self?.refreshSelectedMetric()
    }
    private lazy var hubs = ActionButton("Manage Hubs…", symbol: "link", style: .subtle) { [weak self] in
        self?.onManageHubs?()
    }
    private var metric = Metric.cost
    private var period = UsagePeriod.week
    private var provider: String?
    private var providerChoices: [String] = []
    private var presented = false
    private var connection: UUID?
    private var modelFilter: Wire = .null
    private var report: UsageReport?
    private var historyError: String?
    private var limitsError: String?
    private var resetResult: (message: String, warning: Bool)?
    private var redeeming: UsageResetTarget?
    private var historyTask: Task<Void, Never>?
    private var limitsTask: Task<Void, Never>?
    private var readHistoryAt: ContinuousClock.Instant?
    var onBack: (() -> Void)?
    var onManageHubs: (() -> Void)?

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = Surface(WorkspaceStyle.canvas)
        let heading = column([label("Usage", size: 20, weight: .semibold, color: WorkspaceStyle.ink), environment], spacing: 2)
        let header = row([back, heading, NSView(), refresh], spacing: 10)
        metrics.segmentCount = 3
        metrics.trackingMode = .selectOne
        metrics.segmentStyle = .rounded
        for (index, title) in ["Cost", "Tokens", "Limits"].enumerated() {
            metrics.setLabel(title, forSegment: index)
            metrics.setWidth(53, forSegment: index)
        }
        metrics.selectedSegment = metric.rawValue
        metrics.setAccessibilityLabel("Usage Metric")
        metrics.target = self
        metrics.action = #selector(selectMetric)
        periodMenu.addItems(withTitles: UsagePeriod.allCases.map(\.title))
        periodMenu.selectItem(withTitle: period.title)
        periodMenu.setAccessibilityLabel("Usage Period")
        periodMenu.target = self
        periodMenu.action = #selector(selectPeriod)
        providerMenu.setAccessibilityLabel("Usage Provider")
        providerMenu.target = self
        providerMenu.action = #selector(selectProvider)
        let filters = row([metrics, NSView(), hubs, periodMenu, providerMenu], spacing: 6)
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        let layout = column([header, filters, divider(), scroll], spacing: 11, alignment: .width)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.addSubview(layout)
        layout.translatesAutoresizingMaskIntoConstraints = false
        let preferredWidth = layout.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -36)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            preferredWidth,
            layout.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -36),
            layout.widthAnchor.constraint(lessThanOrEqualToConstant: 810),
            layout.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            layout.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            layout.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
    }

    func setPresented(_ presented: Bool) {
        self.presented = presented
        if presented { sync() }
        else { cancelRequests() }
    }

    func selectLimits() {
        let _ = view
        metric = .limits
        metrics.selectedSegment = Metric.limits.rawValue
        provider = nil
        sync()
        scrollToTop()
    }

    func sync(configurationOnly: Bool = false) {
        guard presented else { return }
        if configurationOnly, metric != .limits, connection == workspace.connectionID, modelFilter == workspace.usageModelFilter { return }
        let _ = view
        if connection != workspace.connectionID {
            cancelRequests()
            connection = workspace.connectionID
            report = nil
            historyError = nil
            limitsError = nil
            resetResult = nil
            redeeming = nil
            readHistoryAt = nil
        }
        if modelFilter != workspace.usageModelFilter {
            modelFilter = workspace.usageModelFilter
            invalidateHistory()
        }
        if metric == .limits {
            if !configurationOnly, limitsError == nil {
                refreshLimits(automatic: true)
            }
        } else if historyError == nil, (readHistoryAt?.duration(to: .now) ?? .seconds(60)) >= .seconds(60) {
            readHistory()
        }
        render()
    }

    @objc private func selectMetric() {
        guard let selection = Metric(rawValue: metrics.selectedSegment), selection != metric else { return }
        metric = selection
        sync()
        scrollToTop()
    }

    @objc private func selectPeriod() {
        guard UsagePeriod.allCases.indices.contains(periodMenu.indexOfSelectedItem) else { return }
        period = UsagePeriod.allCases[periodMenu.indexOfSelectedItem]
        invalidateHistory()
        sync()
        scrollToTop()
    }

    @objc private func selectProvider() {
        let index = providerMenu.indexOfSelectedItem - 1
        provider = providerChoices.indices.contains(index) ? providerChoices[index] : nil
        render()
        scrollToTop()
    }

    private func refreshSelectedMetric() {
        if metric == .limits { refreshLimits() }
        else { readHistory(refreshRates: metric == .cost) }
        render()
    }

    private func invalidateHistory() {
        historyTask?.cancel()
        historyTask = nil
        report = nil
        historyError = nil
        readHistoryAt = nil
    }

    private func cancelRequests() {
        historyTask?.cancel()
        historyTask = nil
        limitsTask?.cancel()
        limitsTask = nil
    }

    private func readHistory(refreshRates: Bool = false) {
        guard historyTask == nil, let connection, workspace.can("diagnostics:read") else { return }
        let window = UsageWindow(period: period)
        var payload = window.payload
        if modelFilter != .null { payload["modelFilter"] = modelFilter }
        historyError = nil
        historyTask = Task { [weak self] in
            guard let self else { return }
            do {
                if refreshRates { _ = try? await workspace.request("server.refreshUsageRates") }
                try Task.checkCancellation()
                guard workspace.connectionID == connection else { return }
                let initial = try await workspace.request("server.getUsageSummary", payload)
                try Task.checkCancellation()
                guard workspace.connectionID == connection else { return }
                let snapshot = try UsageReport(initial, window: window)
                report = snapshot
                if snapshot.refreshing {
                    if metric != .limits { render() }
                    payload["awaitRefresh"] = .bool(true)
                    let fresh = try await workspace.request("server.getUsageSummary", payload)
                    try Task.checkCancellation()
                    guard workspace.connectionID == connection else { return }
                    report = try UsageReport(fresh, window: window)
                }
            } catch {
                guard !Task.isCancelled, workspace.connectionID == connection else { return }
                historyError = error.localizedDescription
            }
            readHistoryAt = .now
            historyTask = nil
            if metric != .limits { render() }
        }
    }

    private func refreshLimits(automatic: Bool = false) {
        guard limitsTask == nil, let connection, workspace.can("orchestration:read") else { return }
        limitsError = nil
        limitsTask = Task { [weak self] in
            guard let self else { return }
            do { try await workspace.usageLimitRefresh.run(automatic: automatic) }
            catch {
                guard !Task.isCancelled, workspace.connectionID == connection else { return }
                limitsError = error.localizedDescription
            }
            guard !Task.isCancelled, workspace.connectionID == connection else { return }
            limitsTask = nil
            if metric == .limits { render() }
        }
    }

    private func render() {
        environment.stringValue = workspace.environment?.name ?? "No environment"
        let showingLimits = metric == .limits
        let canRead = workspace.can(showingLimits ? "orchestration:read" : "diagnostics:read")
        refresh.isEnabled = canRead && (showingLimits ? limitsTask == nil : historyTask == nil)
        periodMenu.isHidden = showingLimits
        periodMenu.isEnabled = canRead
        hubs.isHidden = !showingLimits || !canRead || workspace.usageHubSettings.configurations == nil
        let limits = workspace.providers.compactMap(\.usageLimit) + workspace.usageLimitSources.flatMap(\.accounts)
        let choices = canRead ? (showingLimits ? Array(Set(limits.map(\.driver))).sorted() : report?.providers ?? []) : []
        if choices != providerChoices || providerMenu.numberOfItems == 0 {
            providerChoices = choices
            providerMenu.removeAllItems()
            providerMenu.addItem(withTitle: "All Providers")
            for driver in choices { providerMenu.addItem(withTitle: UsageLimitAccount.providerTitle(driver)) }
        }
        let providerIndex = provider.flatMap { choices.firstIndex(of: $0) }
        providerMenu.selectItem(at: providerIndex.map { $0 + 1 } ?? 0)
        providerMenu.isHidden = choices.count < 2
        let selectedProvider = providerIndex.map { choices[$0] }
        let content: [NSView]
        if connection == nil { content = [note("Connect an environment to see usage.")] }
        else if !canRead {
            content = [note(showingLimits ? "This connection can’t read provider limits." : "This connection needs Diagnostics access to view usage.")]
        } else if showingLimits {
            content = renderLimits(limits.filter { selectedProvider == nil || $0.driver == selectedProvider })
        } else {
            content = renderHistory(provider: selectedProvider)
        }
        document.subviews.forEach { $0.removeFromSuperview() }
        fill(column(content, spacing: 10, alignment: .width), in: document, inset: 3)
    }

    private func renderHistory(provider: String?) -> [NSView] {
        guard let report else {
            return [note(historyError ?? "Reading usage from this environment…", error: historyError != nil)]
        }
        let breakdown = report.breakdown(provider: provider)
        let priced = breakdown.total.records > breakdown.total.unpriced
        let headline = label(metric.heading, size: 14, weight: .semibold, color: WorkspaceStyle.ink)
        let total = label(metric == .cost && !priced ? "—" : metric.format(metric.amount(breakdown.total)),
                          size: 22, weight: .medium, color: WorkspaceStyle.ink)
        total.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        let readout = label(size: 11, weight: .medium, color: WorkspaceStyle.secondary)
        let axis = row([label(report.window.labels.first ?? "", size: 11, color: WorkspaceStyle.muted),
                        NSView(), readout, NSView(), label(report.window.labels.last ?? "", size: 11, color: WorkspaceStyle.muted)])
        let spacers = axis.arrangedSubviews
        spacers[1].widthAnchor.constraint(equalTo: spacers[3].widthAnchor).isActive = true
        let values = report.window.keys.map { metric.amount(breakdown.intervals[$0] ?? UsageTotals()) }
        let readings = zip(report.window.labels, values).map { "\($0.0) · \(metric.format($0.1))" }
        let chart = UsageChart(values: values)
        chart.heightAnchor.constraint(equalToConstant: 95).isActive = true
        chart.setAccessibilityLabel(metric == .cost ? "Cost over time" : "Token usage over time")
        chart.setAccessibilityValue(readings.joined(separator: "\n"))
        chart.onInspect = { index in readout.stringValue = index.map { readings[$0] } ?? "" }
        var content: [NSView] = [row([headline, NSView(), total]), chart, axis]
        if let historyError { content.append(note(historyError, error: true)) }
        else if historyTask != nil { content.append(note("Refreshing usage…")) }
        if !report.incompleteSources.isEmpty {
            let names = report.incompleteSources.map(UsageLimitAccount.providerTitle).joined(separator: ", ")
            content.append(note("Some usage couldn’t be read for \(names)."))
        }
        if breakdown.models.isEmpty {
            content.append(note("No usage was recorded in this period."))
            return content
        }
        if metric == .cost && breakdown.total.unpriced > 0 {
            content.append(note("\(breakdown.total.unpriced.formatted()) records have no price. Cost covers priced records."))
        }
        let inputOutput = metric == .tokens ? "\(metric.format(breakdown.total.input)) input · \(metric.format(breakdown.total.output)) output" : ""
        content += [divider(), row([label("Models", size: 13, weight: .semibold), NSView(), label(inputOutput, size: 11, color: WorkspaceStyle.muted)])]
        let models = breakdown.models.sorted { lhs, rhs in
            let left = metric.amount(lhs.value), right = metric.amount(rhs.value)
            if left != right { return left > right }
            return (lhs.key.provider, lhs.key.name) < (rhs.key.provider, rhs.key.name)
        }
        for (model, totals) in models {
            let name = label(model.name, size: 12, color: WorkspaceStyle.ink)
            name.toolTip = model.name
            let driver = label(UsageLimitAccount.providerTitle(model.provider), size: 11, color: WorkspaceStyle.muted)
            let amount = metric == .cost && totals.records <= totals.unpriced ? "Unpriced" : metric.format(metric.amount(totals))
            let number = label(amount, size: 12, color: WorkspaceStyle.secondary)
            number.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            number.setContentCompressionResistancePriority(.required, for: .horizontal)
            content.append(row([name, driver, NSView(), number]))
        }
        return content
    }

    private func renderLimits(_ accounts: [UsageLimitAccount]) -> [NSView] {
        var content: [NSView] = []
        if let resetResult { content.append(note(resetResult.message, error: resetResult.warning)) }
        if let limitsError { content.append(note(limitsError, error: true)) }
        else if limitsTask != nil { content.append(note("Refreshing provider limits…")) }
        for source in workspace.usageLimitSources {
            if let notice = source.notice { content.append(note("\(source.name) · \(notice)", error: true)) }
            else if source.accounts.isEmpty { content.append(note("\(source.name) · No accounts reported")) }
        }
        for account in accounts {
            if !content.isEmpty { content.append(divider()) }
            let name = label(account.title, size: 14, weight: .semibold, color: WorkspaceStyle.ink)
            name.toolTip = account.title
            let plan = label(account.detail, size: 11, color: WorkspaceStyle.muted)
            let checked = account.checkedAt.map { "Checked \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
            content.append(row([name, plan, NSView(), label(checked, size: 11, color: WorkspaceStyle.muted)]))
            if let notice = account.notice { content.append(note(notice, error: true)) }
            if let external = account.externalUsage {
                let link = ActionButton(external.label, symbol: "arrow.up.right", style: .subtle) {
                    NSWorkspace.shared.open(external.url)
                }
                content.append(row([link, NSView()]))
            }
            for window in account.windows {
                let percent = (window.remaining / 100).formatted(.percent.precision(.fractionLength(0...1)))
                let reset = window.resetsAt.map { "Resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
                let status = label("\(percent) remaining", size: 11.5, weight: .medium, color: WorkspaceStyle.ink)
                status.setContentCompressionResistancePriority(.required, for: .horizontal)
                let progress = UsageChart(values: [window.remaining], limit: 100)
                progress.heightAnchor.constraint(equalToConstant: 5).isActive = true
                content += [row([label(window.label, size: 12), NSView(), label(reset, size: 11, color: WorkspaceStyle.muted), status]), progress]
            }
            for reset in account.resets {
                let balance = reset.count == 1 ? "1 reset credit available" : "\(reset.count) reset credits available"
                let expiry = reset.expiresAt.map { "Expires \($0.formatted(date: .abbreviated, time: .shortened))" }
                let title = [reset.label, balance, expiry].compactMap { $0 }.joined(separator: " · ")
                let description = label(title, size: 11.5, color: WorkspaceStyle.secondary)
                description.toolTip = reset.description
                if let target = reset.target, workspace.can("providers:manage") {
                    let use = ActionButton(redeeming == target ? "Using…" : "Use Reset…", style: .subtle) { [weak self] in
                        self?.confirmReset(target, reset: reset, account: account.title)
                    }
                    use.setAccessibilityLabel("Use \(reset.label ?? "reset credit") for \(account.title)")
                    use.isEnabled = redeeming == nil
                    content.append(row([description, NSView(), use]))
                } else {
                    content.append(description)
                }
            }
        }
        if content.isEmpty { content = [note("This environment hasn’t reported provider limits.")] }
        return content
    }

    private func confirmReset(_ target: UsageResetTarget, reset: UsageLimitAccount.Reset, account: String) {
        guard redeeming == nil, workspace.can("providers:manage"), let connection = workspace.connectionID,
              let window = view.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Use \(reset.label ?? "a reset credit") for \(account)?"
        alert.informativeText = reset.description.map { "This spends one credit. \($0)" } ??
            "This spends one credit and clears the current rate-limit windows."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Use Reset Credit")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn, self.workspace.connectionID == connection else { return }
            self.redeem(target, connection: connection)
        }
    }

    private func redeem(_ target: UsageResetTarget, connection: UUID) {
        guard redeeming == nil else { return }
        redeeming = target
        resetResult = nil
        render()
        Task { [weak self, workspace] in
            let result: (String, Bool)
            do {
                let status = try await workspace.redeemUsageCredit(target, connection: connection)
                result = (status.message, status.warning)
            } catch {
                result = (error.localizedDescription, true)
            }
            guard let self, workspace.connectionID == connection else { return }
            self.resetResult = result
            self.redeeming = nil
            if self.presented && self.metric == .limits { self.render() }
        }
    }

    private func scrollToTop() {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func note(_ text: String, error: Bool = false) -> NSTextField {
        let view = NSTextField(wrappingLabelWithString: text)
        view.font = .systemFont(ofSize: 12)
        view.textColor = error ? WorkspaceStyle.negative : WorkspaceStyle.muted
        return view
    }

    private func divider() -> NSView {
        let view = Surface(WorkspaceStyle.line)
        view.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return view
    }
}

private final class UsageDocument: NSView {
    override var isFlipped: Bool { true }
}

private final class UsageChart: NSView {
    private let values: [Double]
    private let limit: Double?
    private var tracking: NSTrackingArea?
    private var inspected: Int?
    var onInspect: ((Int?) -> Void)?

    init(values: [Double], limit: Double? = nil) {
        self.values = values
        self.limit = limit
        super.init(frame: .zero)
        setAccessibilityElement(limit == nil)
        if limit == nil { setAccessibilityRole(.image) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        guard onInspect != nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.contains(point), !values.isEmpty else { inspect(nil); return }
        let index = Int((point.x - bounds.minX) / bounds.width * CGFloat(values.count))
        inspect(values.indices.contains(index) ? index : nil)
    }

    override func mouseExited(with event: NSEvent) { inspect(nil) }

    private func inspect(_ index: Int?) {
        guard index != inspected else { return }
        inspected = index
        onInspect?(index)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        WorkspaceStyle.line.setFill()
        if let limit, let value = values.first {
            bounds.fill()
            WorkspaceStyle.accent.setFill()
            NSRect(x: 0, y: 0, width: bounds.width * value / limit, height: bounds.height).fill()
            return
        }
        for fraction in [0.0, 0.5, 1.0] {
            NSRect(x: 0, y: (bounds.height - 1) * fraction, width: bounds.width, height: 1).fill()
        }
        guard let peak = values.max(), !values.isEmpty else { return }
        let step = bounds.width / CGFloat(values.count)
        if let inspected {
            WorkspaceStyle.composer.setFill()
            NSRect(x: CGFloat(inspected) * step, y: 1, width: step, height: bounds.height - 2).fill()
        }
        guard peak > 0 else { return }
        let width = min(27, step * 0.76)
        WorkspaceStyle.accent.setFill()
        for (index, value) in values.enumerated() where value > 0 {
            let rect = NSRect(x: CGFloat(index) * step + (step - width) / 2, y: 1, width: width,
                              height: max(1, (bounds.height - 1) * value / peak))
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
