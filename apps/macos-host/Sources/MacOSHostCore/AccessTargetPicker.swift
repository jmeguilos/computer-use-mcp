import AppKit
import Foundation

/// Access selection is deliberately metadata-only. The host must not capture a
/// target merely to make an approval prompt more visually attractive.
public enum AccessTargetPreviewPolicy: String, Equatable, Sendable {
    case metadataOnly
}

public enum AccessTargetKindPresentation: String, Equatable, Sendable {
    case window = "Window"
    case display = "Display"
}

public struct AccessTargetChoicePresentation: Equatable, Sendable {
    public let index: Int
    public let targetKey: String
    public let kind: AccessTargetKindPresentation
    public let title: String
    public let identifier: String
    public let bounds: String
    public let displayContext: String
    public let accessibilityLabel: String
}

public struct VerifiedApplicationIconIdentity: Equatable, Sendable {
    public let processID: Int32
    public let bundleIdentifier: String
    public let signingIdentity: String
    public let processStartTimeUnixMs: Int64
}

public struct AccessTargetPickerPresentation: Equatable, Sendable {
    public let previewPolicy: AccessTargetPreviewPolicy
    public let requester: String
    public let reason: String
    public let capabilityLabels: [String]
    public let applicationName: String?
    public let bundleIdentifier: String?
    public let identityStatus: String
    public let verifiedIconIdentity: VerifiedApplicationIconIdentity?
    public let choices: [AccessTargetChoicePresentation]
    public let isSessionOnly: Bool
    public let canRememberApplication: Bool
    public let applicationAlreadyRemembered: Bool
    public let persistenceExplanation: String

    public static func make(_ request: AccessApprovalRequest) -> AccessTargetPickerPresentation {
        let sanitizedTitles = request.candidates.map { choice in
            let title = NativeUISanitizer.escaped(
                choice.title,
                maximumInputUTF16: 512,
                maximumOutputUTF16: 768
            )
            return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (request.displayTarget ? "Unnamed display" : "Untitled window")
                : title
        }
        let titleCounts = Dictionary(grouping: sanitizedTitles, by: { $0 }).mapValues(\.count)
        var titleOrdinals: [String: Int] = [:]

        let choices = request.candidates.enumerated().map { index, choice in
            let title = sanitizedTitles[index]
            titleOrdinals[title, default: 0] += 1
            let duplicateOrdinal = titleOrdinals[title, default: 1]
            let duplicateCount = titleCounts[title, default: 1]
            let kind: AccessTargetKindPresentation
            let identifier: String
            let displayContext: String
            switch choice.scope {
            case .window(let identity):
                kind = .window
                let duplicate = duplicateCount > 1
                    ? "Window \(duplicateOrdinal) of \(duplicateCount) • "
                    : ""
                identifier = "\(duplicate)Window ID \(identity.windowID)"
                let displayID = choice.targetMetadata.objectValue?["displayId"]?.stringValue.map {
                    NativeUISanitizer.escaped(
                        $0,
                        maximumInputUTF16: 128,
                        maximumOutputUTF16: 384
                    )
                }
                displayContext = bounded(
                    "\(displayID.map { "On display \($0)" } ?? "Containing display") • " +
                    "display bounds \(boundsString(choice.displayFrame))"
                )
            case .display(let display):
                kind = .display
                identifier = "Display ID \(display.displayID)"
                var contextParts = [display.isMain ? "Main display" : "Secondary display"]
                if display.isMirrored { contextParts.append("Mirrored") }
                contextParts.append(
                    "\(number(display.pixelSize.width)) × \(number(display.pixelSize.height)) px"
                )
                let scaleDescription: String
                if abs(display.pointPixelScaleX - display.pointPixelScaleY) < 0.000_1 {
                    scaleDescription = "\(number(display.pointPixelScale))× scale"
                } else {
                    scaleDescription = "\(number(display.pointPixelScaleX))× × " +
                        "\(number(display.pointPixelScaleY))× scale"
                }
                contextParts.append(scaleDescription)
                displayContext = bounded(contextParts.joined(separator: " • "))
            }
            let bounds = boundsString(choice.frame)
            let accessibilityLabel = bounded(
                "\(kind.rawValue), \(identifier), title \(title), bounds \(bounds), \(displayContext)"
            )
            return AccessTargetChoicePresentation(
                index: index,
                targetKey: choice.targetKey,
                kind: kind,
                title: title,
                identifier: identifier,
                bounds: bounds,
                displayContext: displayContext,
                accessibilityLabel: accessibilityLabel
            )
        }

        let requester = NativeUISanitizer.escaped(
            request.requesterName,
            maximumInputUTF16: 128,
            maximumOutputUTF16: 384
        )
        let reason = NativeUISanitizer.escaped(
            request.reason,
            maximumInputUTF16: 500,
            maximumOutputUTF16: 1_500
        )
        let applicationName = request.applicationName.map {
            NativeUISanitizer.escaped($0, maximumInputUTF16: 256, maximumOutputUTF16: 512)
        }
        let bundleIdentifier = request.bundleIdentifier.map {
            NativeUISanitizer.escaped($0, maximumInputUTF16: 512, maximumOutputUTF16: 1_024)
        }
        let iconIdentity = coherentWindowIdentity(request)
        let identityStatus: String
        if request.displayTarget {
            identityStatus = "Display identity provided by macOS"
        } else if iconIdentity != nil {
            identityStatus = "Verified running app identity"
        } else {
            identityStatus = "Target metadata provided by macOS"
        }
        let persistenceExplanation: String
        if request.displayTarget {
            persistenceExplanation = "Session only. Display approval is never remembered."
        } else if request.appConsentExists {
            persistenceExplanation = "App identity remembered. This approval still applies only to the exact window selected above."
        } else {
            persistenceExplanation = "Allow once, or remember this verified app identity. Every new window still requires an exact selection."
        }

        return AccessTargetPickerPresentation(
            previewPolicy: .metadataOnly,
            requester: requester,
            reason: reason,
            capabilityLabels: capabilityLabels(request.capabilities),
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            identityStatus: identityStatus,
            verifiedIconIdentity: iconIdentity,
            choices: choices,
            isSessionOnly: request.displayTarget,
            canRememberApplication: !request.displayTarget && !request.appConsentExists,
            applicationAlreadyRemembered: !request.displayTarget && request.appConsentExists,
            persistenceExplanation: persistenceExplanation
        )
    }

    public func selectionSummary(at index: Int) -> String? {
        guard choices.indices.contains(index) else { return nil }
        let choice = choices[index]
        return "Selected exact \(choice.kind.rawValue.lowercased()) • \(choice.identifier) • title: \(choice.title)"
    }

    private static func coherentWindowIdentity(
        _ request: AccessApprovalRequest
    ) -> VerifiedApplicationIconIdentity? {
        guard !request.displayTarget, !request.candidates.isEmpty else { return nil }
        let identities = request.candidates.compactMap { choice -> WindowIdentity? in
            guard case .window(let identity) = choice.scope else { return nil }
            return identity
        }
        guard identities.count == request.candidates.count, let first = identities.first,
              request.bundleIdentifier == nil || request.bundleIdentifier == first.bundleIdentifier,
              identities.allSatisfy({ identity in
                  identity.processID == first.processID &&
                      identity.bundleIdentifier == first.bundleIdentifier &&
                      identity.signingIdentity == first.signingIdentity &&
                      identity.processStartTimeUnixMs == first.processStartTimeUnixMs
              }) else { return nil }
        return VerifiedApplicationIconIdentity(
            processID: first.processID,
            bundleIdentifier: first.bundleIdentifier,
            signingIdentity: first.signingIdentity,
            processStartTimeUnixMs: first.processStartTimeUnixMs
        )
    }

    private static func capabilityLabels(_ capabilities: Set<PublicCapability>) -> [String] {
        capabilities.map { capability in
            switch capability {
            case .observe: return "View"
            case .interact: return "Interact"
            case .clipboardWrite: return "Clipboard write"
            }
        }.sorted()
    }

    private static func boundsString(_ rect: Rect) -> String {
        "\(number(rect.size.width)) × \(number(rect.size.height)) pt " +
            "at (\(number(rect.origin.x)), \(number(rect.origin.y)))"
    }

    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "?" }
        if value.rounded() == value { return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value) }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func bounded(_ value: String) -> String {
        NativeUISanitizer.boundedLiteral(value, maximumUTF16: 2_048)
    }
}

public enum AccessTargetPickerLayout {
    /// Leave room for the alert title, explanation, and decision buttons. The
    /// accessory becomes vertically scrollable instead of allowing NSAlert to
    /// place its buttons beyond a small display's visible frame.
    public static func viewportHeight(
        contentHeight: CGFloat,
        visibleScreenHeight: CGFloat
    ) -> CGFloat {
        guard contentHeight.isFinite, visibleScreenHeight.isFinite,
              contentHeight > 0, visibleScreenHeight > 0 else { return 300 }
        let alertAccessoryBudget = max(300, visibleScreenHeight - 240)
        return min(contentHeight, 500, alertAccessoryBudget)
    }
}

@MainActor
private enum VerifiedApplicationIconResolver {
    static func icon(for identity: VerifiedApplicationIconIdentity?) -> NSImage? {
        guard let identity,
              let running = NSRunningApplication(processIdentifier: identity.processID),
              running.bundleIdentifier == identity.bundleIdentifier,
              running.launchDate.map({ Int64($0.timeIntervalSince1970 * 1_000) }) == identity.processStartTimeUnixMs,
              ProcessCodeIdentity.designatedRequirementDigest(processID: identity.processID) == identity.signingIdentity,
              let bundleURL = running.bundleURL?.resolvingSymlinksInPath(),
              bundleURL.isFileURL,
              bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              Bundle(url: bundleURL)?.bundleIdentifier == identity.bundleIdentifier,
              (try? bundleURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: bundleURL.path)
    }
}

@MainActor
private final class NativeAccessTargetPickerDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class NativeAccessTargetPickerView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let presentation: AccessTargetPickerPresentation
    private let tableView = NSTableView()
    private let selectionLabel = NSTextField(labelWithString: "")
    private let clearSelectionButton = NSButton(title: "Clear Selection", target: nil, action: nil)
    private let persistenceStatus = NSTextField(labelWithString: "")
    let rememberButton = NSButton(
        checkboxWithTitle: "Remember this verified app identity for future requests",
        target: nil,
        action: nil
    )
    var onSelectionChanged: ((Bool) -> Void)?

    var selectedIndex: Int? {
        let row = tableView.selectedRow
        return presentation.choices.indices.contains(row) ? row : nil
    }

    var selectedPersistence: GrantPersistence {
        if presentation.isSessionOnly { return .sessionOnly }
        return rememberButton.state == .on ? .alwaysAllowApp : .allowOnce
    }

    init(request: AccessApprovalRequest) {
        presentation = .make(request)
        let tableHeight = min(236, max(86, presentation.choices.count * 78))
        let contentHeight = CGFloat(360 + tableHeight)
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 720
        let viewportHeight = AccessTargetPickerLayout.viewportHeight(
            contentHeight: contentHeight,
            visibleScreenHeight: visibleHeight
        )
        super.init(frame: NSRect(x: 0, y: 0, width: 540, height: viewportHeight))
        configure(tableHeight: CGFloat(tableHeight), contentHeight: contentHeight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func numberOfRows(in tableView: NSTableView) -> Int { presentation.choices.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 76 }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard presentation.choices.indices.contains(row) else { return nil }
        let choice = presentation.choices[row]
        let cell = NSTableCellView()
        cell.setAccessibilityElement(true)
        // NSTableView owns row selection and exposes the standard selectable
        // table semantics to VoiceOver. Do not claim a radio-button role for a
        // view that has no independent AXPress action.
        cell.setAccessibilityRole(.group)
        cell.setAccessibilityLabel(choice.accessibilityLabel)
        cell.setAccessibilityHelp(
            "Use the surrounding target table to select this exact \(choice.kind.rawValue.lowercased())."
        )

        let symbolName = choice.kind == .window ? "macwindow" : "display"
        let icon = NSImageView(image: NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)
        cell.addSubview(icon)

        let kind = label("\(choice.kind.rawValue.uppercased())  •  \(choice.identifier)", size: 10, weight: .semibold)
        kind.textColor = .secondaryLabelColor
        let title = label(choice.title, size: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let metadata = label("\(choice.bounds)  •  \(choice.displayContext)", size: 10, weight: .regular)
        metadata.textColor = .secondaryLabelColor
        metadata.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [kind, title, metadata])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }

    @objc private func persistenceChanged() { updatePersistence() }

    private func configure(tableHeight: CGFloat, contentHeight: CGFloat) {
        let scrollContainer = NSScrollView()
        scrollContainer.translatesAutoresizingMaskIntoConstraints = false
        scrollContainer.hasVerticalScroller = contentHeight > frame.height
        scrollContainer.autohidesScrollers = true
        scrollContainer.drawsBackground = false
        scrollContainer.borderType = .noBorder
        scrollContainer.setAccessibilityLabel("Access request details and exact target picker")

        let document = NativeAccessTargetPickerDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollContainer.documentView = document
        addSubview(scrollContainer)

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(root)
        NSLayoutConstraint.activate([
            scrollContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollContainer.topAnchor.constraint(equalTo: topAnchor),
            scrollContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scrollContainer.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollContainer.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollContainer.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scrollContainer.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualToConstant: contentHeight),
            root.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            root.topAnchor.constraint(equalTo: document.topAnchor),
            root.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        root.addArrangedSubview(identityCard())
        root.addArrangedSubview(requestCard())

        let privacy = label(
            "Privacy: target previews are not captured before approval. Selection uses verified identity and window/display metadata only.",
            size: 10,
            weight: .regular,
            wrapping: true
        )
        privacy.textColor = .secondaryLabelColor
        privacy.setAccessibilityLabel("Privacy notice")
        privacy.setAccessibilityValue(privacy.stringValue)
        constrainWidth(privacy)
        root.addArrangedSubview(privacy)

        let targetHeading = label("Choose one exact target", size: 12, weight: .semibold)
        constrainWidth(targetHeading)
        root.addArrangedSubview(targetHeading)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("target"))
        column.resizingMask = .autoresizingMask
        column.width = 516
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 76
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = .clear
        tableView.setAccessibilityLabel("Exact target selection")
        tableView.setAccessibilityHelp("Metadata only. No target preview is captured before approval.")

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = presentation.choices.count > 3
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 540),
            scroll.heightAnchor.constraint(equalToConstant: tableHeight),
        ])
        root.addArrangedSubview(scroll)

        selectionLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        selectionLabel.lineBreakMode = .byTruncatingMiddle
        selectionLabel.setAccessibilityLabel("Current exact target selection")
        clearSelectionButton.bezelStyle = .inline
        clearSelectionButton.controlSize = .small
        clearSelectionButton.target = self
        clearSelectionButton.action = #selector(clearSelection)
        clearSelectionButton.setAccessibilityHelp("Removes the current target choice and disables approval.")
        let selectionRow = NSStackView(views: [selectionLabel, clearSelectionButton])
        selectionRow.orientation = .horizontal
        selectionRow.alignment = .centerY
        selectionRow.distribution = .fill
        constrainWidth(selectionRow)
        selectionLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        clearSelectionButton.setContentHuggingPriority(.required, for: .horizontal)
        root.addArrangedSubview(selectionRow)

        root.addArrangedSubview(persistenceView())
        updateSelection()
        updatePersistence()
    }

    private func identityCard() -> NSView {
        let card = roundedCard()
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.image = VerifiedApplicationIconResolver.icon(for: presentation.verifiedIconIdentity)
            ?? NSImage(
                systemSymbolName: presentation.isSessionOnly ? "display" : "app.badge.checkmark",
                accessibilityDescription: nil
            )
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)

        let name = label(
            presentation.applicationName ?? (presentation.isSessionOnly ? "macOS display" : "Application"),
            size: 14,
            weight: .semibold
        )
        let identity = label(
            [presentation.identityStatus, presentation.bundleIdentifier].compactMap { $0 }.joined(separator: "  •  "),
            size: 10,
            weight: .regular
        )
        identity.textColor = .secondaryLabelColor
        identity.lineBreakMode = .byTruncatingMiddle
        let text = NSStackView(views: [name, identity])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(icon)
        card.addSubview(text)
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel(
            [name.stringValue, identity.stringValue].filter { !$0.isEmpty }.joined(separator: ", ")
        )
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 540),
            card.heightAnchor.constraint(equalToConstant: 62),
            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            text.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            text.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        return card
    }

    private func requestCard() -> NSView {
        let card = roundedCard()
        let requester = label("Requester: \(presentation.requester)", size: 11, weight: .semibold)
        let capabilities = label(
            "Requested capabilities: \(presentation.capabilityLabels.joined(separator: ", "))",
            size: 11,
            weight: .regular
        )
        let reason = label("Reason: \(presentation.reason)", size: 10, weight: .regular, wrapping: true)
        reason.textColor = .secondaryLabelColor
        reason.maximumNumberOfLines = 3
        reason.lineBreakMode = .byTruncatingTail
        reason.toolTip = "Reason: \(presentation.reason)"
        let stack = NSStackView(views: [requester, capabilities, reason])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel(
            "Requester \(presentation.requester). Requested capabilities \(presentation.capabilityLabels.joined(separator: ", ")). Reason \(presentation.reason)"
        )
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 540),
            card.heightAnchor.constraint(equalToConstant: 86),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -9),
        ])
        return card
    }

    private func persistenceView() -> NSView {
        let card = roundedCard()
        let heading = label("Access duration", size: 11, weight: .semibold)
        persistenceStatus.font = .systemFont(ofSize: 10)
        persistenceStatus.textColor = .secondaryLabelColor
        persistenceStatus.lineBreakMode = .byTruncatingTail
        persistenceStatus.toolTip = presentation.persistenceExplanation

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.addArrangedSubview(heading)
        if !presentation.isSessionOnly {
            rememberButton.state = presentation.applicationAlreadyRemembered ? .on : .off
            rememberButton.isEnabled = presentation.canRememberApplication
            rememberButton.target = self
            rememberButton.action = #selector(persistenceChanged)
            rememberButton.setAccessibilityHelp(
                "Remembering an app identity never selects or grants a new window automatically."
            )
            stack.addArrangedSubview(rememberButton)
        }
        stack.addArrangedSubview(persistenceStatus)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel("Access duration")
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 540),
            card.heightAnchor.constraint(equalToConstant: presentation.isSessionOnly ? 54 : 76),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        return card
    }

    private func updateSelection() {
        selectionLabel.stringValue = selectedIndex.flatMap { presentation.selectionSummary(at: $0) }
            ?? "No exact target selected"
        selectionLabel.setAccessibilityValue(selectionLabel.stringValue)
        clearSelectionButton.isEnabled = selectedIndex != nil
        onSelectionChanged?(selectedIndex != nil)
    }

    @objc private func clearSelection() {
        tableView.deselectAll(nil)
        updateSelection()
    }

    private func updatePersistence() {
        if presentation.isSessionOnly {
            persistenceStatus.stringValue = presentation.persistenceExplanation
        } else if rememberButton.state == .on {
            persistenceStatus.stringValue = "Remembered app identity; this grant remains limited to the selected exact window."
        } else {
            persistenceStatus.stringValue = "Allow once; revoked on Stop, disconnect, replacement, or inactivity."
        }
        persistenceStatus.setAccessibilityValue(persistenceStatus.stringValue)
    }

    private func roundedCard() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    private func constrainWidth(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 540).isActive = true
    }

    private func label(
        _ value: String,
        size: CGFloat,
        weight: NSFont.Weight,
        wrapping: Bool = false
    ) -> NSTextField {
        let field = wrapping
            ? NSTextField(wrappingLabelWithString: value)
            : NSTextField(labelWithString: value)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.isSelectable = true
        return field
    }
}
