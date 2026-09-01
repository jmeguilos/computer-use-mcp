import AppKit
import MacOSHostCore

/// Presentation-only status for one macOS permission card. The application
/// delegate maps native permission checks into this type and calls `render`.
enum ComputerControlPermissionTone: Equatable, Sendable {
    case ready
    case needsAction
    case waiting
    case caution
}

struct ComputerControlPermissionCardState: Equatable, Sendable {
    let statusText: String
    let detailText: String
    let actionTitle: String?
    let actionEnabled: Bool
    let tone: ComputerControlPermissionTone

    init(
        statusText: String,
        detailText: String,
        actionTitle: String? = nil,
        actionEnabled: Bool = true,
        tone: ComputerControlPermissionTone
    ) {
        self.statusText = statusText
        self.detailText = detailText
        self.actionTitle = actionTitle
        self.actionEnabled = actionEnabled
        self.tone = tone
    }

    static let checking = ComputerControlPermissionCardState(
        statusText: "Checking",
        detailText: "Reading the current macOS privacy setting.",
        actionEnabled: false,
        tone: .waiting
    )
}

/// `id` is an opaque UI identifier supplied by the host. Signing requirements
/// remain outside the view layer and are never exposed as actionable UI data.
struct ComputerControlRememberedApp: Equatable, Sendable, Identifiable {
    let id: String
    let displayName: String
    let bundleIdentifier: String
    let accessSummary: String

    init(
        id: String,
        displayName: String,
        bundleIdentifier: String,
        accessSummary: String
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.accessSummary = accessSummary
    }
}

struct ComputerControlWindowState: Equatable, Sendable {
    let sourceDevelopmentBuild: Bool
    let sourceBuildMessage: String
    let generalAccessEnabled: Bool
    let overallStatusText: String
    let screenVisibility: ComputerControlPermissionCardState
    let appInteraction: ComputerControlPermissionCardState
    let rememberedApps: [ComputerControlRememberedApp]

    init(
        sourceDevelopmentBuild: Bool,
        sourceBuildMessage: String = "This source build cannot enforce the release signing boundary. Use non-sensitive windows while testing it.",
        generalAccessEnabled: Bool,
        overallStatusText: String,
        screenVisibility: ComputerControlPermissionCardState,
        appInteraction: ComputerControlPermissionCardState,
        rememberedApps: [ComputerControlRememberedApp]
    ) {
        self.sourceDevelopmentBuild = sourceDevelopmentBuild
        self.sourceBuildMessage = sourceBuildMessage
        self.generalAccessEnabled = generalAccessEnabled
        self.overallStatusText = overallStatusText
        self.screenVisibility = screenVisibility
        self.appInteraction = appInteraction
        self.rememberedApps = rememberedApps
    }

    static let loading = ComputerControlWindowState(
        sourceDevelopmentBuild: false,
        generalAccessEnabled: false,
        overallStatusText: "Checking local access",
        screenVisibility: .checking,
        appInteraction: .checking,
        rememberedApps: []
    )
}

/// Original AppKit first-run and settings surface. It deliberately owns no TCC,
/// consent-store, or grant policy. Callers wire the closures below and drive all
/// visible state through `render(_:)`.
@MainActor
final class ComputerControlWindowController: NSWindowController, NSWindowDelegate {
    var onGeneralAccessChanged: ((Bool) -> Void)?
    var onScreenVisibilityAction: (() -> Void)?
    var onAppInteractionAction: (() -> Void)?
    var onRemoveRememberedApp: ((String) -> Void)?
    var onRemoveAllRememberedApps: (() -> Void)?
    var onCheckAgain: (() -> Void)?
    var onDone: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let overallStatusLabel = NSTextField(labelWithString: "")
    private let sourceWarning = SourceBuildWarningView()
    private let generalAccess = GeneralAccessView()
    private let screenCard = PermissionCardView(
        title: "Screen visibility",
        systemImageName: "rectangle.on.rectangle",
        accessibilitySummary: "Screen visibility permission"
    )
    private let interactionCard = PermissionCardView(
        title: "App interaction",
        systemImageName: "hand.tap",
        accessibilitySummary: "App interaction permission"
    )
    private let rememberedApps = RememberedAppsView()
    private let checkAgainButton = NSButton(title: "Check Again", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private var dismissNotificationPending = false
    private var renderedRememberedApps: [ComputerControlRememberedApp]?

    init(initialState: ComputerControlWindowState = .loading) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Computer Use MCP Host"
        window.minSize = NSSize(width: 560, height: 520)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.moveToActiveSpace]
        super.init(window: window)
        window.delegate = self
        configureContent()
        configureCallbacks()
        render(initialState)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ComputerControlWindowController does not support NSCoder")
    }

    /// Brings the settings window forward without changing any permission or
    /// grant state. The caller decides whether first-run presentation is needed.
    func present() {
        dismissNotificationPending = true
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closes the window only after the application delegate has durably
    /// recorded onboarding completion. A failed write leaves the window open
    /// and setup incomplete so the user can see the error and retry.
    func closeAfterSuccessfulCompletion() {
        close()
    }

    /// Re-renders every stateful control. This is safe to call after native TCC
    /// prompts, application activation, consent removal, or a periodic refresh.
    func render(_ state: ComputerControlWindowState) {
        overallStatusLabel.stringValue = state.overallStatusText
        overallStatusLabel.setAccessibilityLabel("Host status: \(state.overallStatusText)")
        sourceWarning.render(
            visible: state.sourceDevelopmentBuild,
            message: state.sourceBuildMessage
        )
        generalAccess.render(enabled: state.generalAccessEnabled)
        screenCard.render(state.screenVisibility)
        interactionCard.render(state.appInteraction)
        // The settings refresh timer should not destroy and recreate unchanged
        // rows: doing so discards keyboard focus and VoiceOver's current item.
        if renderedRememberedApps != state.rememberedApps {
            rememberedApps.render(state.rememberedApps)
            renderedRememberedApps = state.rememberedApps
        }
        checkAgainButton.isEnabled = true
    }

    func windowWillClose(_ notification: Notification) {
        guard dismissNotificationPending else { return }
        dismissNotificationPending = false
        onDismiss?()
    }

    private func configureContent() {
        guard let contentView = window?.contentView else { return }

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let documentView = FlippedContentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        contentView.addSubview(scrollView)

        let contentStack = NSStackView()
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 16
        documentView.addSubview(contentStack)

        let header = makeHeaderView()
        let permissionHeading = makeSectionHeading(
            title: "macOS access",
            detail: "These system settings do not grant a client access to a window by themselves."
        )
        let privacyExplanation = makePrivacyExplanation()

        contentStack.addArrangedSubview(header)
        contentStack.addArrangedSubview(sourceWarning)
        contentStack.addArrangedSubview(generalAccess)
        contentStack.addArrangedSubview(permissionHeading)
        contentStack.addArrangedSubview(screenCard)
        contentStack.addArrangedSubview(interactionCard)
        contentStack.addArrangedSubview(privacyExplanation)
        contentStack.addArrangedSubview(rememberedApps)
        contentStack.addArrangedSubview(makeFooterView())

        for view in contentStack.arrangedSubviews {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -24),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -24),
        ])

        window?.setAccessibilityLabel("Computer Use MCP Host settings")
    }

    private func configureCallbacks() {
        generalAccess.onChanged = { [weak self] enabled in
            self?.onGeneralAccessChanged?(enabled)
        }
        screenCard.onAction = { [weak self] in self?.onScreenVisibilityAction?() }
        interactionCard.onAction = { [weak self] in self?.onAppInteractionAction?() }
        rememberedApps.onRemove = { [weak self] identifier in
            self?.onRemoveRememberedApp?(identifier)
        }
        rememberedApps.onRemoveAll = { [weak self] in
            self?.onRemoveAllRememberedApps?()
        }

        checkAgainButton.target = self
        checkAgainButton.action = #selector(checkAgainPressed)
        doneButton.target = self
        doneButton.action = #selector(donePressed)
    }

    private func makeHeaderView() -> NSView {
        let container = NSView()
        let icon = symbolImageView(
            named: "cursorarrow.rays",
            description: "Computer control settings",
            pointSize: 28,
            weight: .medium
        )
        icon.contentTintColor = .controlAccentColor

        let title = NSTextField(labelWithString: "Computer Use MCP Host")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = .labelColor

        let subtitle = wrappingLabel(
            "Choose what this local helper may do before an MCP client asks for a specific window or display."
        )
        subtitle.textColor = .secondaryLabelColor

        overallStatusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        overallStatusLabel.textColor = .secondaryLabelColor
        overallStatusLabel.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [title, subtitle, overallStatusLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(icon)
        container.addSubview(textStack)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            icon.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            icon.widthAnchor.constraint(equalToConstant: 44),
            icon.heightAnchor.constraint(equalToConstant: 44),
            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            textStack.topAnchor.constraint(equalTo: container.topAnchor),
            textStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func makeSectionHeading(title: String, detail: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        let detailLabel = wrappingLabel(detail)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        return stack
    }

    private func makePrivacyExplanation() -> NSView {
        let panel = InsetPanelView(backgroundColor: .controlBackgroundColor)
        panel.setAccessibilityLabel("Exact-window and privacy information")

        let icon = symbolImageView(
            named: "lock.shield",
            description: "Privacy boundary",
            pointSize: 17,
            weight: .medium
        )
        icon.contentTintColor = .secondaryLabelColor

        let title = NSTextField(labelWithString: "A separate choice still protects each target")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = wrappingLabel(
            "macOS grants access to this host as a whole. A connected client receives no window or display access until you approve a separate request. The host keeps no screenshot history; approved frames are returned to that client, which may send them to its model provider. Input Monitoring is not requested."
        )
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [title, detail])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(icon)
        panel.addSubview(textStack)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            icon.topAnchor.constraint(equalTo: panel.topAnchor, constant: 15),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            textStack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 13),
            textStack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -13),
        ])
        return panel
    }

    private func makeFooterView() -> NSView {
        let container = NSView()
        let spacer = NSView()
        checkAgainButton.bezelStyle = .rounded
        checkAgainButton.setAccessibilityLabel("Check macOS permissions and always-allowed app access again")
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.setAccessibilityLabel("Close Computer Use MCP Host settings")

        let stack = NSStackView(views: [spacer, checkAgainButton, doneButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 1),
        ])
        return container
    }

    @objc private func checkAgainPressed() {
        guard let onCheckAgain else { return }
        checkAgainButton.isEnabled = false
        onCheckAgain()
    }

    @objc private func donePressed() {
        onDone?()
    }
}

@MainActor
private final class GeneralAccessView: InsetPanelView {
    var onChanged: ((Bool) -> Void)?

    private let accessSwitch = NSSwitch()
    private var renderedEnabled = false

    init() {
        super.init(backgroundColor: .controlBackgroundColor)

        let title = NSTextField(labelWithString: "General app access")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let detail = wrappingLabel(
            "Allow connected MCP clients to present new window or display access requests. Turning this off also stops active grants."
        )
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor

        let labels = NSStackView(views: [title, detail])
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4

        accessSwitch.translatesAutoresizingMaskIntoConstraints = false
        accessSwitch.target = self
        accessSwitch.action = #selector(switchChanged)
        accessSwitch.setAccessibilityLabel("Accept new app access requests")
        accessSwitch.setAccessibilityHelp(
            "Controls whether connected MCP clients may ask for a new window or display grant."
        )

        addSubview(labels)
        addSubview(accessSwitch)
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            labels.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            labels.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
            accessSwitch.leadingAnchor.constraint(greaterThanOrEqualTo: labels.trailingAnchor, constant: 16),
            accessSwitch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            accessSwitch.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityLabel("General app access")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GeneralAccessView does not support NSCoder")
    }

    func render(enabled: Bool) {
        renderedEnabled = enabled
        accessSwitch.state = enabled ? .on : .off
        accessSwitch.isEnabled = true
        accessSwitch.setAccessibilityValue(enabled ? "On" : "Off")
    }

    @objc private func switchChanged() {
        let requestedValue = accessSwitch.state == .on
        // Preference persistence and grant revocation are security-sensitive.
        // Do not visually claim the new state until the owner acknowledges it
        // with a fresh render after durable policy enforcement.
        accessSwitch.state = renderedEnabled ? .on : .off
        guard let onChanged else { return }
        accessSwitch.isEnabled = false
        onChanged(requestedValue)
    }
}

@MainActor
private final class PermissionCardView: InsetPanelView {
    var onAction: (() -> Void)?

    private let titleText: String
    private let accessibilitySummary: String
    private let statusBadge = StatusBadgeView()
    private let detailLabel = wrappingLabel("")
    private let actionButton = NSButton(title: "", target: nil, action: nil)

    init(title: String, systemImageName: String, accessibilitySummary: String) {
        self.titleText = title
        self.accessibilitySummary = accessibilitySummary
        super.init(backgroundColor: .controlBackgroundColor)

        let icon = symbolImageView(
            named: systemImageName,
            description: accessibilitySummary,
            pointSize: 17,
            weight: .medium
        )
        icon.contentTintColor = .secondaryLabelColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)

        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor

        let titleRow = NSStackView(views: [titleLabel, NSView(), statusBadge])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8

        let textStack = NSStackView(views: [titleRow, detailLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 5

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(actionPressed)

        addSubview(icon)
        addSubview(textStack)
        addSubview(actionButton)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 15),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            actionButton.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 14),
            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 108),
        ])
        setAccessibilityLabel(accessibilitySummary)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PermissionCardView does not support NSCoder")
    }

    func render(_ state: ComputerControlPermissionCardState) {
        statusBadge.render(text: state.statusText, tone: state.tone)
        detailLabel.stringValue = state.detailText
        detailLabel.setAccessibilityLabel("\(titleText) details: \(state.detailText)")

        if let actionTitle = state.actionTitle {
            actionButton.title = actionTitle
            actionButton.isHidden = false
            actionButton.isEnabled = state.actionEnabled
            actionButton.setAccessibilityLabel("\(actionTitle) for \(titleText)")
        } else {
            actionButton.isHidden = true
            actionButton.isEnabled = false
        }
        setAccessibilityHelp("Status: \(state.statusText). \(state.detailText)")
    }

    @objc private func actionPressed() {
        guard let onAction else { return }
        actionButton.isEnabled = false
        onAction()
    }
}

@MainActor
private final class RememberedAppsView: NSView {
    var onRemove: ((String) -> Void)?
    var onRemoveAll: (() -> Void)?

    private let rows = NSStackView()
    private let removeAllButton = NSButton(title: "Remove All", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RememberedAppsView does not support NSCoder")
    }

    func render(_ apps: [ComputerControlRememberedApp]) {
        for view in rows.arrangedSubviews {
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        removeAllButton.isEnabled = !apps.isEmpty
        removeAllButton.setAccessibilityHelp(
            apps.isEmpty ? "There are no always-allowed apps." : "Removes every always-allowed app decision."
        )

        guard !apps.isEmpty else {
            let empty = wrappingLabel(
                "No apps are always allowed. Future app access requests will ask before creating an exact-window grant."
            )
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            let holder = InsetPanelView(backgroundColor: .controlBackgroundColor)
            holder.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 14),
                empty.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -14),
                empty.topAnchor.constraint(equalTo: holder.topAnchor, constant: 14),
                empty.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -14),
            ])
            rows.addArrangedSubview(holder)
            holder.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            return
        }

        for app in apps {
            let row = RememberedAppRow(app: app)
            row.onRemove = { [weak self] in self?.onRemove?(app.id) }
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }

    private func configure() {
        let title = NSTextField(labelWithString: "Always-allowed apps")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let detail = wrappingLabel(
            "An explicit request may reuse approval only for the same requester and signed app when exactly one safe window matches. Ambiguous windows and sensitive actions still ask. Legacy prompt-only decisions are labeled below."
        )
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor

        removeAllButton.bezelStyle = .rounded
        removeAllButton.controlSize = .small
        removeAllButton.target = self
        removeAllButton.action = #selector(removeAllPressed)
        removeAllButton.setAccessibilityLabel("Remove all always-allowed app access")

        let titleRow = NSStackView(views: [title, NSView(), removeAllButton])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8

        let heading = NSStackView(views: [titleRow, detail])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 3

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8

        let stack = NSStackView(views: [heading, rows])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rows.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        setAccessibilityLabel("Always-allowed app access")
    }

    @objc private func removeAllPressed() {
        guard let onRemoveAll else { return }
        removeAllButton.isEnabled = false
        defer { removeAllButton.isEnabled = true }
        onRemoveAll()
    }
}

@MainActor
private final class RememberedAppRow: InsetPanelView {
    var onRemove: (() -> Void)?
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)

    init(app: ComputerControlRememberedApp) {
        super.init(backgroundColor: .controlBackgroundColor)

        let displayName = NativeUISanitizer.escaped(
            app.displayName,
            maximumInputUTF16: 256,
            maximumOutputUTF16: 512
        )
        let bundleIdentifier = NativeUISanitizer.escaped(
            app.bundleIdentifier,
            maximumInputUTF16: 512,
            maximumOutputUTF16: 1_024
        )
        let accessSummary = NativeUISanitizer.escaped(
            app.accessSummary,
            maximumInputUTF16: 512,
            maximumOutputUTF16: 1_024
        )

        let icon = symbolImageView(
            named: "app",
            description: "Always-allowed application",
            pointSize: 18,
            weight: .regular
        )
        icon.contentTintColor = .secondaryLabelColor

        let name = NSTextField(labelWithString: displayName)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        let identifier = NSTextField(labelWithString: bundleIdentifier)
        identifier.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        identifier.textColor = .tertiaryLabelColor
        identifier.lineBreakMode = .byTruncatingMiddle
        let summary = wrappingLabel(accessSummary)
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor

        let labels = NSStackView(views: [name, identifier, summary])
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.target = self
        removeButton.action = #selector(removePressed)
        removeButton.bezelStyle = .rounded
        removeButton.controlSize = .small
        removeButton.setAccessibilityLabel("Remove always-allowed access for \(displayName)")

        addSubview(icon)
        addSubview(labels)
        addSubview(removeButton)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 15),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            labels.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            labels.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            removeButton.leadingAnchor.constraint(greaterThanOrEqualTo: labels.trailingAnchor, constant: 12),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityLabel("\(displayName), \(bundleIdentifier), \(accessSummary)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RememberedAppRow does not support NSCoder")
    }

    @objc private func removePressed() {
        guard let onRemove else { return }
        removeButton.isEnabled = false
        defer { removeButton.isEnabled = true }
        onRemove()
    }
}

@MainActor
private final class SourceBuildWarningView: InsetPanelView {
    private let messageLabel = wrappingLabel("")

    init() {
        super.init(
            backgroundColor: NSColor.systemOrange.withAlphaComponent(0.10),
            borderColor: NSColor.systemOrange.withAlphaComponent(0.34)
        )

        let icon = symbolImageView(
            named: "exclamationmark.triangle.fill",
            description: "Source development build warning",
            pointSize: 16,
            weight: .medium
        )
        icon.contentTintColor = .systemOrange
        let title = NSTextField(labelWithString: "Source development build")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor

        let labels = NSStackView(views: [title, messageLabel])
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        addSubview(icon)
        addSubview(labels)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            labels.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            labels.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SourceBuildWarningView does not support NSCoder")
    }

    func render(visible: Bool, message: String) {
        isHidden = !visible
        messageLabel.stringValue = message
        setAccessibilityLabel("Source development build. \(message)")
    }
}

@MainActor
private final class StatusBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var badgeBackgroundColor = NSColor.clear

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StatusBadgeView does not support NSCoder")
    }

    func render(text: String, tone: ComputerControlPermissionTone) {
        label.stringValue = text
        let foreground: NSColor
        let background: NSColor
        switch tone {
        case .ready:
            foreground = .systemGreen
            background = NSColor.systemGreen.withAlphaComponent(0.12)
        case .needsAction:
            foreground = .systemOrange
            background = NSColor.systemOrange.withAlphaComponent(0.12)
        case .waiting:
            foreground = .secondaryLabelColor
            background = NSColor.secondaryLabelColor.withAlphaComponent(0.10)
        case .caution:
            foreground = .systemRed
            background = NSColor.systemRed.withAlphaComponent(0.10)
        }
        label.textColor = foreground
        badgeBackgroundColor = background
        needsDisplay = true
        setAccessibilityLabel("Status: \(text)")
    }

    override func draw(_ dirtyRect: NSRect) {
        badgeBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}

@MainActor
private class InsetPanelView: NSView {
    private let panelBackgroundColor: NSColor
    private let panelBorderColor: NSColor

    init(backgroundColor: NSColor, borderColor: NSColor = .separatorColor) {
        panelBackgroundColor = backgroundColor
        panelBorderColor = borderColor
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("InsetPanelView does not support NSCoder")
    }

    override func draw(_ dirtyRect: NSRect) {
        let borderRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: borderRect, xRadius: 10, yRadius: 10)
        panelBackgroundColor.setFill()
        path.fill()
        panelBorderColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

@MainActor
private final class FlippedContentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private func wrappingLabel(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.translatesAutoresizingMaskIntoConstraints = false
    label.maximumNumberOfLines = 0
    label.lineBreakMode = .byWordWrapping
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
}

@MainActor
private func symbolImageView(
    named name: String,
    description: String,
    pointSize: CGFloat,
    weight: NSFont.Weight
) -> NSImageView {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?
        .withSymbolConfiguration(configuration)
    let imageView = NSImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.image = image
    imageView.imageScaling = .scaleProportionallyDown
    imageView.setAccessibilityLabel(description)
    return imageView
}
