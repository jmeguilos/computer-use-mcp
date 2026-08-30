import AppKit
import CoreGraphics
import Foundation

public struct ScreenGeometry: Equatable, Sendable {
    public let quartzTopLeftFrame: Rect
    public let appKitFrame: Rect
    public init(quartzTopLeftFrame: Rect, appKitFrame: Rect) {
        self.quartzTopLeftFrame = quartzTopLeftFrame
        self.appKitFrame = appKitFrame
    }
}

public enum AppKitCoordinateConverter {
    public static func convert(topLeftFrame: Rect, on screen: ScreenGeometry) -> Rect {
        let quartz = screen.quartzTopLeftFrame
        let appKit = screen.appKitFrame
        return Rect(
            origin: Point(
                x: appKit.origin.x + (topLeftFrame.origin.x - quartz.origin.x),
                y: appKit.origin.y + appKit.size.height -
                    (topLeftFrame.origin.y - quartz.origin.y) - topLeftFrame.size.height
            ),
            size: topLeftFrame.size
        )
    }
}

public enum AccessChoiceLabeler {
    public static func labels(for choices: [GrantChoice]) -> [String] {
        let titles = choices.map {
            NativeUISanitizer.escaped(
                $0.title,
                maximumInputUTF16: 512,
                maximumOutputUTF16: 768
            )
        }
        let titleCounts = Dictionary(grouping: titles, by: { $0 }).mapValues(\.count)
        return choices.enumerated().map { index, choice in
            let title = titles[index]
            guard titleCounts[title, default: 0] > 1 else { return title }
            let frame = choice.frame
            let detail = "\(title) — Window \(index + 1), " +
                "\(String(format: "%.0f", frame.size.width))×\(String(format: "%.0f", frame.size.height)) " +
                "at (\(String(format: "%.0f", frame.origin.x)), \(String(format: "%.0f", frame.origin.y)))"
            return NativeUISanitizer.boundedLiteral(
                detail,
                maximumUTF16: 1_024
            )
        }
    }
}

public enum NativeAccessPromptText {
    public static func launchMessage(_ request: LaunchApprovalRequest) -> String {
        "Launch \(NativeUISanitizer.escaped(request.appName, maximumInputUTF16: 256, maximumOutputUTF16: 512))?"
    }

    public static func launchDetails(_ request: LaunchApprovalRequest) -> String {
        let requester = NativeUISanitizer.escaped(
            request.requesterName,
            maximumInputUTF16: 128,
            maximumOutputUTF16: 384
        )
        let bundle = NativeUISanitizer.escaped(
            request.bundleIdentifier,
            maximumInputUTF16: 512,
            maximumOutputUTF16: 1_024
        )
        let reason = NativeUISanitizer.escaped(
            request.reason,
            maximumInputUTF16: 500,
            maximumOutputUTF16: 1_500
        )
        let capabilities = capabilityLabels(request.capabilities).joined(separator: ", ")
        return "Requester: \(requester)\nApplication identity: \(bundle)\n" +
            "Requested access: \(capabilities)\nRequester-provided reason: \(reason)\n\n" +
            "Opening the app does not grant control. After launch, the host will either ask for an exact-window choice or, when an existing Always Allow App policy resolves to exactly one safe window, create a fresh visible exact-window grant."
    }

    public static func accessDetails(_ request: AccessApprovalRequest) -> String {
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
        let capabilities = capabilityLabels(request.capabilities).joined(separator: ", ")
        let consentNote = request.appConsentExists
            ? "\nThis app identity is remembered, but this exact target still needs approval."
            : ""
        let appLine: String
        if let appName = request.applicationName, let bundle = request.bundleIdentifier {
            appLine = "\nApplication: \(NativeUISanitizer.escaped(appName, maximumInputUTF16: 256, maximumOutputUTF16: 512))" +
                " (\(NativeUISanitizer.escaped(bundle, maximumInputUTF16: 512, maximumOutputUTF16: 1_024)))"
        } else {
            appLine = ""
        }
        let scope = request.displayTarget
            ? "\nScope: Entire selected display. Session only; this choice is never remembered."
            : "\nScope: One selected window."
        return "Requester: \(requester)\(appLine)\(scope)\nRequested access: \(capabilities)\n" +
            "Requester-provided reason: \(reason)\(consentNote)"
    }

    public static func capabilityLabels(_ capabilities: Set<PublicCapability>) -> [String] {
        capabilities.map { capability in
            switch capability {
            case .observe: return "View"
            case .interact: return "Interact"
            case .clipboardWrite: return "Clipboard write"
            }
        }.sorted()
    }
}

public enum SessionLifecyclePolicy {
    public static func shouldRevoke(for notification: Notification.Name) -> Bool {
        notification == NSWorkspace.sessionDidResignActiveNotification ||
            notification == NSWorkspace.willSleepNotification ||
            notification == NSWorkspace.willPowerOffNotification ||
            notification == NSWorkspace.screensDidSleepNotification
    }
}

public enum IndicatorVisibility {
    public static let railWidth: Double = 8
    public static let railHeight: Double = 64

    public static func isFullyOccluded(target: Rect, by occluders: [Rect]) -> Bool {
        var visible = [target.cgRect]
        for occluder in occluders.map(\.cgRect) {
            visible = visible.flatMap { subtract(occluder, from: $0) }
            if visible.isEmpty { return true }
        }
        return false
    }

    public static func attachmentStrip(target: Rect, slot _: Int = 0) -> Rect? {
        let frame = target.cgRect
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { return nil }
        let baseY = frame.minY + min(32, max(0, frame.height - railHeight) / 2)
        let proposed = CGRect(
            // The collapsed panel is placed immediately outside the target's
            // left edge. Test that exact footprint, not an interior band, so
            // the always-on-top rail can never be drawn over an unrelated
            // higher-z-order window occupying the adjacent space.
            x: frame.minX - railWidth,
            // A target-attached rail belongs to that target, so global
            // detached-panel slot allocation must never drift it away.
            y: baseY,
            width: railWidth,
            height: min(railHeight, frame.height)
        )
        return Rect(proposed)
    }

    /// The high-level indicator panel may attach to the exact target only when
    /// the target and its outside left-edge attachment band are completely
    /// unobstructed. Any positive overlap detaches it to the helper-owned
    /// display edge, preventing the rail or its expanded panel from being
    /// visually attributed to an unrelated foreground window.
    public static func canAttachRail(
        target: Rect,
        slot: Int = 0,
        isOnScreen: Bool,
        occluders: [Rect],
        attachmentOccupants: [Rect]? = nil
    ) -> Bool {
        guard isOnScreen,
              let strip = attachmentStrip(target: target, slot: slot),
              !occluders.contains(where: { occluder in
                  let overlap = target.cgRect.intersection(occluder.cgRect)
                  return !overlap.isNull && !overlap.isEmpty
              }) else { return false }
        return !(attachmentOccupants ?? occluders).contains { occluder in
            let overlap = strip.cgRect.intersection(occluder.cgRect)
            return !overlap.isNull && !overlap.isEmpty
        }
    }

    /// Computes a top-left-coordinate panel frame without silently collapsing
    /// multiple detached indicators into the same clamped display-edge slot.
    /// Attached rails always use the target's own left edge and ignore `slot`.
    public static func panelFrame(
        target: Rect,
        display: Rect,
        targetAttached: Bool,
        slot: Int,
        expanded: Bool
    ) -> Rect? {
        let targetFrame = target.cgRect
        let displayFrame = display.cgRect
        let width = expanded ? 188.0 : railWidth
        guard slot >= 0,
              targetFrame.origin.x.isFinite, targetFrame.origin.y.isFinite,
              targetFrame.width.isFinite, targetFrame.height.isFinite,
              displayFrame.origin.x.isFinite, displayFrame.origin.y.isFinite,
              displayFrame.width.isFinite, displayFrame.height.isFinite,
              targetFrame.width > 0, targetFrame.height > 0,
              displayFrame.width >= width, displayFrame.height >= railHeight else { return nil }

        let x: Double
        let y: Double
        if targetAttached {
            let targetX = targetFrame.minX - railWidth
            guard targetX >= displayFrame.minX,
                  targetX < displayFrame.maxX,
                  targetFrame.intersects(displayFrame) else { return nil }
            x = min(targetX, displayFrame.maxX - width)
            let targetY = targetFrame.minY + min(
                32,
                max(0, targetFrame.height - railHeight) / 2
            )
            y = min(
                max(targetY, displayFrame.minY),
                displayFrame.maxY - railHeight
            )
        } else {
            x = displayFrame.minX
            y = displayFrame.minY + 24 + Double(slot) * 72
            // Failing here is deliberate: clamping would pile two grants into
            // one visual slot and make the Stop control's attribution ambiguous.
            guard y >= displayFrame.minY,
                  y + railHeight <= displayFrame.maxY else { return nil }
        }

        return Rect(
            origin: Point(x: x, y: y),
            size: Size(width: width, height: railHeight)
        )
    }

    private static func subtract(_ cover: CGRect, from source: CGRect) -> [CGRect] {
        let intersection = source.intersection(cover)
        guard !intersection.isNull, !intersection.isEmpty else { return [source] }
        var result: [CGRect] = []
        if intersection.minY > source.minY {
            result.append(CGRect(x: source.minX, y: source.minY, width: source.width, height: intersection.minY - source.minY))
        }
        if intersection.maxY < source.maxY {
            result.append(CGRect(x: source.minX, y: intersection.maxY, width: source.width, height: source.maxY - intersection.maxY))
        }
        if intersection.minX > source.minX {
            result.append(CGRect(x: source.minX, y: intersection.minY, width: intersection.minX - source.minX, height: intersection.height))
        }
        if intersection.maxX < source.maxX {
            result.append(CGRect(x: intersection.maxX, y: intersection.minY, width: source.maxX - intersection.maxX, height: intersection.height))
        }
        return result.filter { $0.width > 0 && $0.height > 0 }
    }
}

/// Window-list queries return z-ordered dictionaries and may contain many
/// surfaces. Indicator authority is bound to one concrete WindowServer ID, so
/// callers must never infer identity from list order.
enum IndicatorWindowInfoLookup {
    static func exactEntry(
        in entries: [[String: Any]],
        windowID: UInt32
    ) -> [String: Any]? {
        entries.first { entry in
            (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
        }
    }
}

/// A single WindowServer inventory miss can occur while a window changes
/// focus, Space, or visibility. Keep the detached status panel visible during
/// that bounded transition, but revoke after repeated misses. Action-time host
/// revalidation remains fail-closed throughout the grace interval.
struct IndicatorTransientMissTracker: Equatable, Sendable {
    static let defaultLimit = 3

    let limit: Int
    private(set) var consecutiveMisses = 0

    init(limit: Int = defaultLimit) {
        self.limit = max(1, limit)
    }

    mutating func recordPresent() {
        consecutiveMisses = 0
    }

    /// Returns true when the bounded miss limit has been reached.
    mutating func recordMissing() -> Bool {
        consecutiveMisses = min(limit, consecutiveMisses + 1)
        return consecutiveMisses >= limit
    }
}

/// Restoring focus is safe only while the helper still owns the foreground.
/// If the user switched elsewhere while deciding, their newer choice wins.
enum NativeApprovalFocusPolicy {
    static func shouldRestore(
        priorProcessID: Int32?,
        currentProcessID: Int32?,
        hostProcessID: Int32
    ) -> Bool {
        guard let priorProcessID,
              priorProcessID != hostProcessID,
              currentProcessID == hostProcessID else { return false }
        return true
    }
}

struct NativeAccessApprovalButtonChoice: Equatable, Sendable {
    let title: String
    let persistence: GrantPersistence
}

struct NativeAccessApprovalButtonPlan: Equatable, Sendable {
    let positiveChoices: [NativeAccessApprovalButtonChoice]
    let cancelTitle: String

    static func make(
        displayTarget: Bool,
        appConsentExists: Bool,
        candidateCount: Int
    ) -> NativeAccessApprovalButtonPlan {
        if displayTarget {
            return NativeAccessApprovalButtonPlan(
                positiveChoices: [NativeAccessApprovalButtonChoice(
                    title: "Allow Display for Session",
                    persistence: .sessionOnly
                )],
                cancelTitle: "Not Now"
            )
        }
        if !appConsentExists {
            return NativeAccessApprovalButtonPlan(
                positiveChoices: [
                    NativeAccessApprovalButtonChoice(
                        title: "Allow Once",
                        persistence: .allowOnce
                    ),
                    NativeAccessApprovalButtonChoice(
                        title: "Always Allow App",
                        persistence: .alwaysAllowApp
                    ),
                ],
                cancelTitle: "Not Now"
            )
        }
        guard candidateCount > 1 else {
            // A remembered request with one exact candidate is auto-granted by
            // HostController and must not reach native selection UI. If it ever
            // does, expose no approval path rather than silently broadening the
            // remembered-consent contract.
            return NativeAccessApprovalButtonPlan(
                positiveChoices: [],
                cancelTitle: "Not Now"
            )
        }
        return NativeAccessApprovalButtonPlan(
            positiveChoices: [NativeAccessApprovalButtonChoice(
                title: "Use Selected Window",
                persistence: .alwaysAllowApp
            )],
            cancelTitle: "Not Now"
        )
    }
}

public enum IndicatorPresentationError: Error, Equatable, Sendable {
    case unavailable
}

public final class MacControlIndicator: ControlIndicatorPresenting, @unchecked Sendable {
    private let stopGrant: @Sendable (UUID) async -> Void
    private var panels: [UUID: IndicatorPanelController] = [:]
    private var panelSlots: [UUID: Int] = [:]
    private var grantsByConnection: [UUID: Set<UUID>] = [:]

    public init(stopGrant: @escaping @Sendable (UUID) async -> Void) {
        self.stopGrant = stopGrant
    }

    public func show(_ state: IndicatorState) async throws {
        try await MainActor.run {
            let controller = panels[state.grantID] ?? IndicatorPanelController(
                grantID: state.grantID,
                slot: firstAvailableSlot(),
                stopGrant: stopGrant
            )
            panels[state.grantID] = controller
            panelSlots[state.grantID] = controller.slot
            grantsByConnection[state.connectionID, default: []].insert(state.grantID)
            do {
                try controller.show(state)
            } catch {
                panels.removeValue(forKey: state.grantID)?.close()
                panelSlots.removeValue(forKey: state.grantID)
                grantsByConnection[state.connectionID]?.remove(state.grantID)
                if grantsByConnection[state.connectionID]?.isEmpty == true {
                    grantsByConnection.removeValue(forKey: state.connectionID)
                }
                throw error
            }
        }
    }

    public func hide(connectionID: UUID) async {
        await MainActor.run {
            for id in grantsByConnection.removeValue(forKey: connectionID) ?? [] {
                panels.removeValue(forKey: id)?.close()
                panelSlots.removeValue(forKey: id)
            }
        }
    }

    public func hide(grantID: UUID) async {
        await MainActor.run {
            panels.removeValue(forKey: grantID)?.close()
            panelSlots.removeValue(forKey: grantID)
            for connectionID in Array(grantsByConnection.keys) {
                grantsByConnection[connectionID]?.remove(grantID)
                if grantsByConnection[connectionID]?.isEmpty == true {
                    grantsByConnection.removeValue(forKey: connectionID)
                }
            }
        }
    }

    public func hideAll() async {
        await MainActor.run {
            panels.values.forEach { $0.close() }
            panels.removeAll()
            panelSlots.removeAll()
            grantsByConnection.removeAll()
        }
    }

    @MainActor
    private func firstAvailableSlot() -> Int {
        let used = Set(panelSlots.values)
        return (0...).first(where: { !used.contains($0) }) ?? used.count
    }
}

@MainActor
private final class IndicatorPanelController: NSObject {
    private let panel: NSPanel
    private let root = IndicatorRootView(frame: NSRect(x: 0, y: 0, width: 8, height: 64))
    private let rail = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 64))
    private let disclosure = NSButton(title: "", target: nil, action: nil)
    private let title = NSTextField(labelWithString: "Computer control active")
    private let target = NSTextField(labelWithString: "")
    private let stop = NSButton(title: "Stop", target: nil, action: nil)
    private let grantID: UUID
    let slot: Int
    private let stopGrant: @Sendable (UUID) async -> Void
    private var currentTargetFrame = Rect(origin: Point(x: 0, y: 0), size: Size(width: 1, height: 1))
    private var displayTopLeftFrame = Rect(origin: Point(x: 0, y: 0), size: Size(width: 1, height: 1))
    private var targetWindowID: UInt32?
    private var targetIdentity: WindowIdentity?
    private var targetDisplayIdentity: DisplayIdentity?
    private var expanded = false
    private var trackingTimer: Timer?
    private var targetVisible = true
    private var targetTitle = ""
    private var transientMisses = IndicatorTransientMissTracker()

    init(grantID: UUID, slot: Int, stopGrant: @escaping @Sendable (UUID) async -> Void) {
        self.grantID = grantID
        self.slot = slot
        self.stopGrant = stopGrant
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 8, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        configure()
    }

    func show(_ state: IndicatorState) throws {
        currentTargetFrame = state.targetFrame
        displayTopLeftFrame = state.displayTopLeftFrame
        targetWindowID = state.targetWindowID
        targetIdentity = state.targetIdentity
        targetDisplayIdentity = state.targetDisplayIdentity
        targetTitle = NativeUISanitizer.escaped(
            state.targetTitle,
            maximumInputUTF16: 512,
            maximumOutputUTF16: 768
        )
        let harness = NativeUISanitizer.escaped(
            state.harnessName,
            maximumInputUTF16: 128,
            maximumOutputUTF16: 384
        )
        let mode = NativeUISanitizer.escaped(
            state.mode,
            maximumInputUTF16: 32,
            maximumOutputUTF16: 96
        )
        title.stringValue = state.controlling ? "Controlled by \(harness)" : "Observed by \(harness)"
        root.setAccessibilityHelp("\(mode) access to \(targetTitle). Expand for details or use Emergency Stop.")
        rail.layer?.backgroundColor = (state.controlling ? NSColor.systemOrange : NSColor.systemBlue).cgColor
        updateAccessibilityState(postNotification: false)
        // Validate target identity, display configuration, z-order, and the
        // assigned visual slot before a newly granted rail can flash onscreen.
        guard pollTarget(revokeIdentityChange: false) else {
            throw IndicatorPresentationError.unavailable
        }
        guard updatePlacement() else { throw IndicatorPresentationError.unavailable }
        panel.orderFrontRegardless()
        let visibleBounds = Self.screenGeometries()
            .map { $0.appKitFrame.cgRect }
            .reduce(CGRect.null) { $0.union($1) }
        guard panel.isVisible, visibleBounds.contains(panel.frame) else {
            throw IndicatorPresentationError.unavailable
        }
        startTracking()
    }

    func close() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        panel.orderOut(nil)
    }

    private func configure() {
        panel.level = .statusBar
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.sharingType = .none
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        root.layer?.cornerRadius = 10
        root.layer?.masksToBounds = true
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel("Computer control indicator")
        root.setAccessibilityHelp("Expand for the requester, target, and Emergency Stop control.")
        rail.wantsLayer = true
        rail.layer?.backgroundColor = NSColor.systemOrange.cgColor
        root.addSubview(rail)

        disclosure.frame = rail.frame
        disclosure.isBordered = false
        disclosure.focusRingType = .none
        disclosure.target = self
        disclosure.action = #selector(disclosurePressed)
        disclosure.setAccessibilityElement(true)
        root.addSubview(disclosure)

        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.frame = NSRect(x: 18, y: 36, width: 116, height: 18)
        root.addSubview(title)
        target.font = .systemFont(ofSize: 10)
        target.textColor = .secondaryLabelColor
        target.lineBreakMode = .byTruncatingTail
        target.frame = NSRect(x: 18, y: 13, width: 116, height: 18)
        root.addSubview(target)

        stop.bezelStyle = .rounded
        stop.controlSize = .small
        stop.contentTintColor = .systemRed
        stop.target = self
        stop.action = #selector(stopPressed)
        stop.frame = NSRect(x: 137, y: 19, width: 46, height: 26)
        stop.setAccessibilityLabel("Emergency Stop")
        stop.setAccessibilityHelp("Immediately revokes control of this target.")
        root.addSubview(stop)
        panel.contentView = root
        root.onHoverChanged = { [weak self] hovered in self?.setExpanded(hovered) }
        root.onClick = { [weak self] in self?.setExpanded(!(self?.expanded ?? false)) }
        updateAccessibilityState(postNotification: false)
    }

    @objc private func stopPressed() {
        Task { await stopGrant(grantID) }
    }

    @objc private func disclosurePressed() {
        setExpanded(!expanded)
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        if !updatePlacement(animated: true) {
            expanded = false
            _ = updatePlacement()
        }
        updateAccessibilityState(postNotification: true)
    }

    private func updateAccessibilityState(postNotification: Bool) {
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel(
            expanded ? "Computer control indicator, expanded" : "Computer control indicator"
        )
        disclosure.setAccessibilityLabel(
            expanded ? "Collapse computer control indicator" : "Expand computer control indicator"
        )
        disclosure.setAccessibilityHelp(
            expanded
                ? "Hides the requester, target, and Emergency Stop details."
                : "Shows the requester, target, and Emergency Stop control."
        )
        title.setAccessibilityElement(expanded)
        target.setAccessibilityElement(expanded)
        stop.setAccessibilityElement(expanded)
        if postNotification {
            NSAccessibility.post(element: root, notification: .layoutChanged)
        }
    }

    private func startTracking() {
        guard trackingTimer == nil else { return }
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollTarget() }
        }
    }

    @discardableResult
    private func pollTarget(revokeIdentityChange: Bool = true) -> Bool {
        guard let targetWindowID else {
            guard let expectedDisplay = targetDisplayIdentity,
                  Self.currentDisplayIdentity(for: expectedDisplay) == expectedDisplay else {
                failClosed(revokeGrant: revokeIdentityChange)
                return false
            }
            targetVisible = true
            currentTargetFrame = expectedDisplay.frame
            displayTopLeftFrame = expectedDisplay.frame
            updateTargetLabel()
            guard updatePlacement() else {
                failClosed(revokeGrant: revokeIdentityChange)
                return false
            }
            return true
        }
        // Apple requires optionIncludingWindow to be paired with an above/below
        // option. Use optionAll so hidden, minimized, and other-Space windows
        // remain eligible, then select the exact numeric ID explicitly.
        let entries = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        guard let entry = IndicatorWindowInfoLookup.exactEntry(
            in: entries,
            windowID: targetWindowID
        ),
        let bounds = entry[kCGWindowBounds as String] as? [String: Any],
        let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
            return handleMissingTarget(revokeIdentityChange: revokeIdentityChange)
        }
        transientMisses.recordPresent()
        if let targetIdentity {
            let ownerPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let running = NSRunningApplication(processIdentifier: targetIdentity.processID)
            let generation = running?.launchDate.map { Int64($0.timeIntervalSince1970 * 1_000) }
            let signing = ProcessCodeIdentity.designatedRequirementDigest(processID: targetIdentity.processID)
            guard ownerPID == targetIdentity.processID,
                  running?.bundleIdentifier == targetIdentity.bundleIdentifier,
                  generation == targetIdentity.processStartTimeUnixMs,
                  signing == targetIdentity.signingIdentity else {
                targetVisible = false
                updateTargetLabel()
                failClosed(revokeGrant: revokeIdentityChange)
                return false
            }
            let processName = (entry[kCGWindowOwnerName as String] as? String)
                ?? running?.localizedName
                ?? targetIdentity.ownerName
            let title = entry[kCGWindowName as String] as? String
            guard ProtectedProcessPolicy().evaluateSurface(
                bundleIdentifier: targetIdentity.bundleIdentifier,
                processName: processName,
                processID: targetIdentity.processID,
                title: title
            ).allowed else {
                targetVisible = false
                updateTargetLabel()
                failClosed(revokeGrant: revokeIdentityChange)
                return false
            }
        }
        currentTargetFrame = Rect(frame)
        let stack = SyntheticDestinationGuard.currentStack()
        let targetIndex = stack.firstIndex(where: { $0.windowID == targetWindowID })
        let occluders = targetIndex.map { index in
            stack[..<index].filter {
                $0.alpha > 0.01 && $0.processID != ProcessInfo.processInfo.processIdentifier
            }.map(\.frame)
        } ?? []
        let attachmentOccupants = stack.filter {
            $0.windowID != targetWindowID &&
                $0.alpha > 0.01 &&
                $0.processID != ProcessInfo.processInfo.processIdentifier
        }.map(\.frame)
        targetVisible = IndicatorVisibility.canAttachRail(
            target: currentTargetFrame,
            slot: slot,
            isOnScreen: targetIndex != nil &&
                (entry[kCGWindowIsOnscreen as String] as? Bool) == true,
            occluders: occluders,
            attachmentOccupants: attachmentOccupants
        )
        updateTargetLabel()
        if let nearest = Self.screenGeometries().max(by: {
            $0.quartzTopLeftFrame.cgRect.intersection(frame).visibleArea <
                $1.quartzTopLeftFrame.cgRect.intersection(frame).visibleArea
        }), nearest.quartzTopLeftFrame.cgRect.intersects(frame) {
            displayTopLeftFrame = nearest.quartzTopLeftFrame
        }
        guard updatePlacement() else {
            failClosed(revokeGrant: revokeIdentityChange)
            return false
        }
        return true
    }

    private func handleMissingTarget(revokeIdentityChange: Bool) -> Bool {
        targetVisible = false
        updateTargetLabel()
        guard revokeIdentityChange else {
            failClosed(revokeGrant: false)
            return false
        }
        guard !transientMisses.recordMissing() else {
            failClosed(revokeGrant: true)
            return false
        }

        // Keep attribution visible without attaching to any unrelated app while
        // WindowServer settles. Failure to present that status panel remains an
        // immediate fail-closed condition.
        guard updatePlacement() else {
            failClosed(revokeGrant: true)
            return false
        }
        panel.orderFrontRegardless()
        guard panel.isVisible else {
            failClosed(revokeGrant: true)
            return false
        }
        return true
    }

    @discardableResult
    private func updatePlacement(animated: Bool = false) -> Bool {
        let screens = Self.screenGeometries()
        let geometry = screens.first { $0.quartzTopLeftFrame == displayTopLeftFrame }
            ?? screens.first { $0.quartzTopLeftFrame.cgRect.intersects(displayTopLeftFrame.cgRect) }
            ?? screens.first
        guard let geometry else { return false }
        let display = displayTopLeftFrame.cgRect
        let targetAttached = targetWindowID != nil &&
            targetVisible &&
            currentTargetFrame.cgRect.minX - IndicatorVisibility.railWidth >= display.minX
        guard let topFrame = IndicatorVisibility.panelFrame(
            target: currentTargetFrame,
            display: displayTopLeftFrame,
            targetAttached: targetAttached,
            slot: slot,
            expanded: expanded
        ) else { return false }
        let appKit = AppKitCoordinateConverter.convert(topLeftFrame: topFrame, on: geometry)
        guard geometry.appKitFrame.cgRect.contains(appKit.cgRect) else { return false }
        root.setFrameSize(NSSize(width: topFrame.size.width, height: topFrame.size.height))
        let apply = { self.panel.setFrame(appKit.cgRect, display: true) }
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; apply() }
        }
        else {
            apply()
            guard panel.frame == appKit.cgRect else { return false }
        }
        return true
    }

    private func failClosed(revokeGrant: Bool) {
        panel.orderOut(nil)
        guard revokeGrant else { return }
        trackingTimer?.invalidate()
        trackingTimer = nil
        let grantID = self.grantID
        let stopGrant = self.stopGrant
        Task { await stopGrant(grantID) }
    }

    private func updateTargetLabel() {
        target.stringValue = targetVisible ? targetTitle : "Target not visible — \(targetTitle)"
        target.setAccessibilityLabel(target.stringValue)
    }

    private static func screenGeometries() -> [ScreenGeometry] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let quartz = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            return ScreenGeometry(quartzTopLeftFrame: Rect(quartz), appKitFrame: Rect(screen.frame))
        }
    }

    private static func currentDisplayIdentity(for expected: DisplayIdentity) -> DisplayIdentity? {
        guard CGDisplayIsActive(expected.displayID) != 0,
              NSScreen.screens.contains(where: { screen in
                  guard let number = screen.deviceDescription[
                      NSDeviceDescriptionKey("NSScreenNumber")
                  ] as? NSNumber else { return false }
                  return number.uint32Value == expected.displayID
              }),
              let mode = CGDisplayCopyDisplayMode(expected.displayID) else { return nil }
        let frame = CGDisplayBounds(expected.displayID)
        let logicalSize = Size(frame.size)
        let pixelSize = Size(
            width: Double(mode.pixelWidth),
            height: Double(mode.pixelHeight)
        )
        guard logicalSize.width > 0, logicalSize.height > 0 else { return nil }
        return try? DisplayIdentity(
            displayID: expected.displayID,
            frame: Rect(frame),
            logicalSize: logicalSize,
            pixelSize: pixelSize,
            pointPixelScaleX: pixelSize.width / logicalSize.width,
            pointPixelScaleY: pixelSize.height / logicalSize.height,
            name: expected.name,
            isMain: CGDisplayIsMain(expected.displayID) != 0,
            isMirrored: CGDisplayMirrorsDisplay(expected.displayID) != kCGNullDirectDisplay
        )
    }
}

@MainActor
private final class IndicatorRootView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }
}

private extension CGRect {
    var visibleArea: CGFloat { isNull || isInfinite ? 0 : width * height }
}

@MainActor
private final class NativeModalCancellationMonitor: NSObject {
    private let cancellation: any InteractionCancellationChecking
    private weak var window: NSWindow?
    private var timer: Timer?
    private(set) var wasCancelled = false

    init(cancellation: any InteractionCancellationChecking) {
        self.cancellation = cancellation
    }

    func start(for window: NSWindow) -> Bool {
        self.window = window
        guard isCurrent() else { return false }
        let timer = Timer(
            timeInterval: 0.05,
            target: self,
            selector: #selector(checkCancellation),
            userInfo: nil,
            repeats: true
        )
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        return true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func checkCancellation() {
        guard !isCurrent() else { return }
        // A different nested modal may temporarily own NSApp.modalWindow.
        // Keep polling until this exact alert becomes current; otherwise a
        // hidden runModal invocation could remain blocked forever.
        guard NSApp.modalWindow === window else { return }
        stop()
        NSApp.abortModal()
        window?.orderOut(nil)
    }

    private func isCurrent() -> Bool {
        do {
            try cancellation.check()
            return true
        } catch {
            wasCancelled = true
            return false
        }
    }
}

@MainActor
private func runCancellableModal(
    _ alert: NSAlert,
    cancellation: any InteractionCancellationChecking
) -> NSApplication.ModalResponse {
    // Approval surfaces are helper-owned security UI. Keep them out of every
    // ScreenCaptureKit/CGWindow capture path, just like the active-control rail.
    alert.window.sharingType = .none
    let monitor = NativeModalCancellationMonitor(cancellation: cancellation)
    guard monitor.start(for: alert.window) else { return .abort }
    defer { monitor.stop() }
    let response = alert.runModal()
    return monitor.wasCancelled ? .abort : response
}

@MainActor
private func runForegroundCancellableModal(
    _ alert: NSAlert,
    cancellation: any InteractionCancellationChecking
) -> NSApplication.ModalResponse {
    do {
        try cancellation.check()
    } catch {
        alert.window.orderOut(nil)
        return .abort
    }
    let focusManager = MacApplicationFocusManager()
    let priorFocus = try? focusManager.capture()
    let hostProcessID = ProcessInfo.processInfo.processIdentifier

    // Set capture exclusion before the alert is ever ordered onscreen. The host
    // is an accessory app, so explicitly activate it and raise the security UI.
    alert.window.sharingType = .none
    NSApp.activate(ignoringOtherApps: true)
    alert.window.orderFrontRegardless()

    let response = runCancellableModal(alert, cancellation: cancellation)
    let currentProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    // stopModal does not guarantee that an accessory-app alert is removed on
    // every early-abort path. Never leave stale approval UI onscreen.
    alert.window.orderOut(nil)
    if let priorFocus,
       NativeApprovalFocusPolicy.shouldRestore(
            priorProcessID: priorFocus.processID,
            currentProcessID: currentProcessID,
            hostProcessID: hostProcessID
       ) {
        _ = focusManager.restore(priorFocus)
    }
    return response
}

public struct NativeAccessApprovalPresenter: AccessApprovalPresenting {
    public init() {}

    public func requestLaunchApproval(
        _ request: LaunchApprovalRequest,
        cancellation: any InteractionCancellationChecking
    ) async -> Bool {
        await MainActor.run {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = NativeAccessPromptText.launchMessage(request)
            alert.informativeText = NativeAccessPromptText.launchDetails(request)
            alert.addButton(withTitle: "Launch App")
            alert.addButton(withTitle: "Deny")
            return runForegroundCancellableModal(
                alert,
                cancellation: cancellation
            ) == .alertFirstButtonReturn
        }
    }

    public func requestApproval(
        _ request: AccessApprovalRequest,
        cancellation: any InteractionCancellationChecking
    ) async -> AccessApprovalDecision {
        await MainActor.run {
            let alert = NSAlert()
            alert.alertStyle = request.displayTarget ? .warning : .informational
            alert.messageText = request.displayTarget ? "Display access request" : "Window access request"
            alert.informativeText = "Choose from verified metadata. No target preview is captured before you approve access."
            let picker = NativeAccessTargetPickerView(request: request)
            alert.accessoryView = picker
            let buttonPlan = NativeAccessApprovalButtonPlan.make(
                displayTarget: request.displayTarget,
                appConsentExists: request.appConsentExists,
                candidateCount: request.candidates.count
            )
            var persistenceByResponse: [Int: GrantPersistence] = [:]
            var positiveButtons: [NSButton] = []
            for (index, choice) in buttonPlan.positiveChoices.enumerated() {
                let button = alert.addButton(withTitle: choice.title)
                button.isEnabled = false
                positiveButtons.append(button)
                persistenceByResponse[
                    NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index
                ] = choice.persistence
            }
            picker.onSelectionChanged = { [positiveButtons] hasSelection in
                positiveButtons.forEach { $0.isEnabled = hasSelection }
            }
            alert.addButton(withTitle: buttonPlan.cancelTitle)
            let response = runForegroundCancellableModal(
                alert,
                cancellation: cancellation
            )
            let selected = picker.selectedIndex.flatMap { index in
                request.candidates.indices.contains(index) ? request.candidates[index] : nil
            }
            if let persistence = persistenceByResponse[response.rawValue] {
                return AccessApprovalDecision(
                    selected: selected,
                    persistence: persistence
                )
            }
            return .denied
        }
    }
}

public struct NativeRiskApprovalPresenter: RiskApprovalPresenting {
    public init() {}
    public func requestApproval(
        _ challenge: RiskChallenge,
        summary: String,
        cancellation: any InteractionCancellationChecking
    ) async -> Bool {
        await MainActor.run {
            let alert = NSAlert()
            alert.alertStyle = challenge.tier == .high ? .critical : .warning
            alert.messageText = "Approve one exact action?"
            let details = "One action only. This approval expires and cannot be reused for a different target or effect.\n\n\(summary)"
            alert.informativeText = NativeUISanitizer.boundedLiteral(
                details,
                maximumUTF16: 4_096
            )
            alert.addButton(withTitle: "Approve Once")
            alert.addButton(withTitle: "Deny")
            return runForegroundCancellableModal(
                alert,
                cancellation: cancellation
            ) == .alertFirstButtonReturn
        }
    }
}
