import AppKit

@MainActor
final class ThreadGoalEditor: NSViewController, NSTextViewDelegate {
    struct Presentation {
        let environmentID: String
        let threadID: String
        let providerThreadID: String?
        let latestRunID: String?
        let working: Bool
        let lastError: String?
        let goal: ThreadGoal
        let driver: ComposerProvider?
        let canEdit: Bool
        let timing: ThreadGoal.Timing?
    }

    private let objective = GoalObjectiveView()
    private let status = label(size: 11.5, color: WorkspaceStyle.muted)
    private let usage = NSTextField(wrappingLabelWithString: "")
    private let notice = NSTextField(wrappingLabelWithString: "")
    private lazy var save = ActionButton("Save", style: .filled) { [weak self] in self?.saveObjective() }
    private lazy var revert = ActionButton("Revert", symbol: "arrow.uturn.backward", iconOnly: true, style: .subtle) {
        [weak self] in self?.revertObjective()
    }
    private lazy var close = ActionButton("Close Goal Editor", symbol: "xmark", iconOnly: true, style: .subtle) {
        [weak self] in self?.onClose?()
    }
    private var presentation: Presentation?
    private var baseObjective = ""
    private var submittedObjective: String?
    private var submittedAfterRunID: String?
    private var saving = false
    private var problem: String?
    private var session = UUID()
    private var confirmation: Task<Void, Never>?
    var onClose: (() -> Void)?
    var onSave: ((String, String) async throws -> Void)?

    var presentsGoal: Bool { presentation != nil }
    var canSave: Bool { onSave != nil && saveCommand != nil }

    override func loadView() {
        view = Surface(WorkspaceStyle.navigation)
        let heading = row([WorkspaceStyle.icon("scope", size: 14, tint: WorkspaceStyle.muted),
                           label("Edit goal", size: 14, weight: .semibold, color: WorkspaceStyle.ink), NSView(), close], spacing: 7)
        let divider = Surface(WorkspaceStyle.line)
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let actions = row([status, NSView(), revert, save], spacing: 6)
        close.widthAnchor.constraint(equalToConstant: 25).isActive = true
        revert.widthAnchor.constraint(equalToConstant: 26).isActive = true
        save.widthAnchor.constraint(greaterThanOrEqualToConstant: 59).isActive = true
        for button in [close, revert, save] { button.heightAnchor.constraint(equalToConstant: 27).isActive = true }
        status.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        usage.font = .systemFont(ofSize: 11.5)
        usage.textColor = WorkspaceStyle.muted
        usage.maximumNumberOfLines = 3
        notice.font = .systemFont(ofSize: 11.5)
        notice.textColor = WorkspaceStyle.muted
        notice.maximumNumberOfLines = 4
        notice.lineBreakMode = .byWordWrapping
        objective.delegate = self
        objective.font = .systemFont(ofSize: 14)
        objective.textColor = WorkspaceStyle.ink
        objective.insertionPointColor = WorkspaceStyle.ink
        objective.textContainerInset = NSSize(width: 0, height: 4)
        objective.isAutomaticQuoteSubstitutionEnabled = false
        objective.isAutomaticDashSubstitutionEnabled = false
        objective.setAccessibilityLabel("Goal")
        objective.onSave = { [weak self] in self?.saveObjective() }
        objective.onClose = { [weak self] in self?.onClose?() }
        let scroll = textScroller(objective)
        objective.allowsUndo = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        fill(column([heading, divider, actions, usage, notice, scroll], spacing: 9, alignment: .width), in: view, inset: 13)
    }

    func open(_ presentation: Presentation) {
        let _ = view
        confirmation?.cancel()
        session = UUID()
        submittedObjective = nil
        submittedAfterRunID = nil
        saving = false
        problem = nil
        self.presentation = presentation
        replaceDraft(with: presentation.goal.objective)
        renderControls()
    }

    func closeEditor() {
        confirmation?.cancel()
        session = UUID()
        presentation = nil
        onSave = nil
    }

    func focus() { view.window?.makeFirstResponder(objective) }

    func render(_ next: Presentation?) {
        guard let previous = presentation else { return }
        guard let next, next.environmentID == previous.environmentID, next.threadID == previous.threadID,
              next.providerThreadID == previous.providerThreadID else {
            onClose?()
            return
        }
        let current = next.goal.objective
        if current != previous.goal.objective {
            confirmation?.cancel()
            let replacedExternally = current != submittedObjective && objective.string != baseObjective
            submittedObjective = nil
            submittedAfterRunID = nil
            if replacedExternally {
                problem = "The goal changed on the host. Revert to load the current version."
            } else {
                problem = nil
                replaceDraft(with: current)
            }
        } else if submittedObjective != nil, next.latestRunID != submittedAfterRunID, !next.working {
            confirmation?.cancel()
            submittedObjective = nil
            submittedAfterRunID = nil
            problem = next.lastError ?? "The provider did not update the goal. Try saving again."
        }
        presentation = next
        renderControls()
    }

    func refreshTime() {
        guard let presentation else { return }
        let value = presentation.timing?.label(at: Date()) ?? presentation.goal.progress ?? presentation.goal.title
        if status.stringValue != value { status.stringValue = value }
        status.toolTip = presentation.goal.title
    }

    func textDidChange(_ notification: Notification) { renderControls() }

    private func replaceDraft(with text: String) {
        baseObjective = text
        objective.string = text
        objective.undoManager?.removeAllActions()
    }

    private func revertObjective() {
        guard let presentation, !saving, submittedObjective == nil else { return }
        problem = nil
        replaceDraft(with: presentation.goal.objective)
        renderControls()
        focus()
    }

    private var saveCommand: String? {
        guard let presentation, let driver = presentation.driver, presentation.canEdit,
              !saving, submittedObjective == nil, baseObjective == presentation.goal.objective,
              objective.string.trimmingCharacters(in: .whitespacesAndNewlines) != baseObjective else { return nil }
        return try? ThreadGoal.editCommand(objective.string, driver: driver)
    }

    private func renderControls() {
        guard let presentation else { return }
        refreshTime()
        let dirty = objective.string != baseObjective
        let goal = presentation.goal
        var metrics = [goal.checkProgress].compactMap { $0 }
        if let tokens = goal.tokensUsed {
            metrics.append(goal.tokenBudget.map { "\(tokens.formatted()) / \($0.formatted()) tokens" } ?? "\(tokens.formatted()) tokens")
        }
        if let check = goal.lastCheck, !check.isEmpty { metrics.append("Last check\n\(check)") }
        usage.stringValue = metrics.joined(separator: "\n")
        usage.toolTip = usage.stringValue
        usage.isHidden = metrics.isEmpty
        objective.isEditable = presentation.canEdit && !saving && submittedObjective == nil
        revert.isEnabled = !saving && submittedObjective == nil && (dirty || baseObjective != presentation.goal.objective)
        save.isEnabled = saveCommand != nil
        save.title = saving || submittedObjective != nil ? "Saving…" : "Save"
        save.setAccessibilityLabel(save.title)
        let validation: String?
        if dirty, presentation.canEdit, let driver = presentation.driver {
            do { _ = try ThreadGoal.editCommand(objective.string, driver: driver); validation = nil }
            catch { validation = error.localizedDescription }
        } else { validation = nil }
        notice.stringValue = problem ?? validation ??
            (submittedObjective != nil ? "Waiting for the provider to apply the goal." :
                presentation.canEdit ? "Saving starts work on the revised goal." : "This goal is read-only.")
        notice.textColor = problem != nil || validation != nil ? WorkspaceStyle.negative : WorkspaceStyle.muted
    }

    func saveObjective() {
        guard let command = saveCommand, let onSave else { return }
        let next = objective.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = baseObjective
        let session = self.session
        submittedObjective = next
        submittedAfterRunID = presentation?.latestRunID
        saving = true
        problem = nil
        renderControls()
        Task { [weak self] in
            do {
                try await onSave(previous, command)
            } catch {
                guard let self, self.session == session else { return }
                submittedObjective = nil
                submittedAfterRunID = nil
                problem = error.localizedDescription
            }
            guard let self, self.session == session else { return }
            saving = false
            renderControls()
            if submittedObjective == next {
                confirmation = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard let self, self.session == session, submittedObjective == next else { return }
                    submittedObjective = nil
                    submittedAfterRunID = nil
                    problem = "The provider has not confirmed the goal. Check its status before saving again."
                    renderControls()
                }
            }
        }
    }
}

@MainActor
private final class GoalObjectiveView: NSTextView {
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if !hasMarkedText(), modifiers.isEmpty, event.keyCode == 53 { onClose?() }
        else if !hasMarkedText(), modifiers == .command, event.keyCode == 36 || event.keyCode == 76 { onSave?() }
        else { super.keyDown(with: event) }
    }
}
