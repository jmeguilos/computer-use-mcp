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
        let capabilities = request.capabilities.map(\.rawValue).sorted().joined(separator: ", ")
        return "Bundle: \(bundle)\nReason: \(reason)\nRequested capabilities: \(capabilities)\n\n" +
            "Launching is separate from granting a window. You will choose the exact window afterward."
    }

    public static func accessDetails(_ request: AccessApprovalRequest) -> String {
        let reason = NativeUISanitizer.escaped(
            request.reason,
            maximumInputUTF16: 500,
            maximumOutputUTF16: 1_500
        )
        let capabilities = request.capabilities.map(\.rawValue).sorted().joined(separator: ", ")
        let consentNote = request.appConsentExists
            ? "\nThis app was previously approved. Choose the exact window for this new grant."
            : ""
        return "Reason: \(reason)\nCapabilities: \(capabilities)\(consentNote)"
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
    public static func isFullyOccluded(target: Rect, by occluders: [Rect]) -> Bool {
        var visible = [target.cgRect]
        for occluder in occluders.map(\.cgRect) {
            visible = visible.flatMap { subtract(occluder, from: $0) }
            if visible.isEmpty { return true }
        }
        return false
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

public enum IndicatorPresentationError: Error, Equatable, Sendable {
    case unavailable
}

public final class MacControlIndicator: ControlIndicatorPresenting, @unchecked Sendable {
    private let stopGrant: @Sendable (UUID) async -> Void
    private var panels: [UUID: IndicatorPanelController] = [:]
    private var grantsByConnection: [UUID: Set<UUID>] = [:]

    public init(stopGrant: @escaping @Sendable (UUID) async -> Void) {
        self.stopGrant = stopGrant
    }

    public func show(_ state: IndicatorState) async throws {
        try await MainActor.run {
            let controller = panels[state.grantID] ?? IndicatorPanelController(
                grantID: state.grantID,
                stopGrant: stopGrant
            )
            panels[state.grantID] = controller
            grantsByConnection[state.connectionID, default: []].insert(state.grantID)
            do {
                try controller.show(state)
            } catch {
                panels.removeValue(forKey: state.grantID)?.close()
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
            }
        }
    }

    public func hide(grantID: UUID) async {
        await MainActor.run {
            panels.removeValue(forKey: grantID)?.close()
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
            grantsByConnection.removeAll()
        }
    }
}

@MainActor
private final class IndicatorPanelController: NSObject {
    private let panel: NSPanel
    private let root = IndicatorRootView(frame: NSRect(x: 0, y: 0, width: 8, height: 64))
    private let rail = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 64))
    private let title = NSTextField(labelWithString: "Computer control active")
    private let target = NSTextField(labelWithString: "")
    private let stop = NSButton(title: "Stop", target: nil, action: nil)
    private let grantID: UUID
    private let stopGrant: @Sendable (UUID) async -> Void
    private var currentTargetFrame = Rect(origin: Point(x: 0, y: 0), size: Size(width: 1, height: 1))
    private var displayTopLeftFrame = Rect(origin: Point(x: 0, y: 0), size: Size(width: 1, height: 1))
    private var targetWindowID: UInt32?
    private var targetIdentity: WindowIdentity?
    private var expanded = false
    private var trackingTimer: Timer?
    private var targetVisible = true

    init(grantID: UUID, stopGrant: @escaping @Sendable (UUID) async -> Void) {
        self.grantID = grantID
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
        target.stringValue = NativeUISanitizer.escaped(
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
        title.stringValue = "\(harness) • \(mode)"
        rail.layer?.backgroundColor = (state.controlling ? NSColor.systemOrange : NSColor.systemBlue).cgColor
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
        rail.wantsLayer = true
        rail.layer?.backgroundColor = NSColor.systemOrange.cgColor
        root.addSubview(rail)

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
        root.addSubview(stop)
        panel.contentView = root
        root.onHoverChanged = { [weak self] hovered in self?.setExpanded(hovered) }
        root.onClick = { [weak self] in self?.setExpanded(!(self?.expanded ?? false)) }
    }

    @objc private func stopPressed() {
        Task { await stopGrant(grantID) }
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        updatePlacement(animated: true)
    }

    private func startTracking() {
        guard trackingTimer == nil else { return }
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollTarget() }
        }
    }

    private func pollTarget() {
        guard let targetWindowID else {
            targetVisible = true
            updatePlacement()
            return
        }
        guard let entries = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow, .excludeDesktopElements],
            CGWindowID(targetWindowID)
        ) as? [[String: Any]],
        let entry = entries.first,
        let bounds = entry[kCGWindowBounds as String] as? [String: Any],
        let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
            targetVisible = false
            updatePlacement()
            return
        }
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
                updatePlacement()
                Task { await stopGrant(grantID) }
                return
            }
        }
        currentTargetFrame = Rect(frame)
        let stack = SyntheticDestinationGuard.currentStack()
        let targetIndex = stack.firstIndex(where: { $0.windowID == targetWindowID })
        let occluders = targetIndex.map { index in
            stack[..<index].filter { $0.alpha > 0.01 }.map(\.frame)
        } ?? []
        targetVisible = (entry[kCGWindowIsOnscreen as String] as? Bool) == true &&
            !IndicatorVisibility.isFullyOccluded(target: currentTargetFrame, by: occluders)
        if let nearest = Self.screenGeometries().max(by: {
            $0.quartzTopLeftFrame.cgRect.intersection(frame).visibleArea <
                $1.quartzTopLeftFrame.cgRect.intersection(frame).visibleArea
        }), nearest.quartzTopLeftFrame.cgRect.intersects(frame) {
            displayTopLeftFrame = nearest.quartzTopLeftFrame
        }
        updatePlacement()
    }

    @discardableResult
    private func updatePlacement(animated: Bool = false) -> Bool {
        let screens = Self.screenGeometries()
        let geometry = screens.first { $0.quartzTopLeftFrame == displayTopLeftFrame }
            ?? screens.first { $0.quartzTopLeftFrame.cgRect.intersects(displayTopLeftFrame.cgRect) }
            ?? screens.first
        guard let geometry else { return false }
        let display = displayTopLeftFrame.cgRect
        let targetFrame = currentTargetFrame.cgRect
        let width: CGFloat = expanded ? 188 : 8
        let desiredX = targetVisible && targetFrame.minX - 14 >= display.minX
            ? targetFrame.minX - 14 : display.minX
        let x = min(max(desiredX, display.minX), max(display.minX, display.maxX - width))
        let desiredY = targetVisible ? targetFrame.minY + min(32, max(0, targetFrame.height - 64) / 2) : display.minY + 24
        let y = min(max(desiredY, display.minY), max(display.minY, display.maxY - 64))
        let topFrame = Rect(origin: Point(x: x, y: y), size: Size(width: width, height: 64))
        let appKit = AppKitCoordinateConverter.convert(topLeftFrame: topFrame, on: geometry)
        guard geometry.appKitFrame.cgRect.contains(appKit.cgRect) else { return false }
        root.setFrameSize(NSSize(width: width, height: 64))
        let apply = { self.panel.setFrame(appKit.cgRect, display: true) }
        if animated { NSAnimationContext.runAnimationGroup { $0.duration = 0.12; apply() } }
        else {
            apply()
            guard panel.frame == appKit.cgRect else { return false }
        }
        return true
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
}

private extension CGRect {
    var visibleArea: CGFloat { isNull || isInfinite ? 0 : width * height }
}

public struct NativeAccessApprovalPresenter: AccessApprovalPresenting {
    public init() {}

    public func requestLaunchApproval(_ request: LaunchApprovalRequest) async -> Bool {
        await MainActor.run {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = NativeAccessPromptText.launchMessage(request)
            alert.informativeText = NativeAccessPromptText.launchDetails(request)
            alert.addButton(withTitle: "Launch App")
            alert.addButton(withTitle: "Deny")
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    public func requestApproval(_ request: AccessApprovalRequest) async -> AccessApprovalDecision {
        await MainActor.run {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Allow computer control?"
            alert.informativeText = NativeAccessPromptText.accessDetails(request)
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
            picker.addItems(withTitles: AccessChoiceLabeler.labels(for: request.candidates))
            alert.accessoryView = picker
            alert.addButton(withTitle: request.displayTarget ? "Allow for Session" : "Allow Once")
            if !request.displayTarget && !request.appConsentExists { alert.addButton(withTitle: "Always Allow App") }
            alert.addButton(withTitle: "Deny")
            let response = alert.runModal()
            let selected = request.candidates.indices.contains(picker.indexOfSelectedItem)
                ? request.candidates[picker.indexOfSelectedItem] : nil
            if response == .alertFirstButtonReturn {
                return AccessApprovalDecision(
                    selected: selected,
                    persistence: request.displayTarget ? .sessionOnly : .allowOnce
                )
            }
            if !request.displayTarget, !request.appConsentExists, response == .alertSecondButtonReturn {
                return AccessApprovalDecision(selected: selected, persistence: .alwaysAllowApp)
            }
            return .denied
        }
    }
}

public struct NativeRiskApprovalPresenter: RiskApprovalPresenting {
    public init() {}
    public func requestApproval(_ challenge: RiskChallenge, summary: String) async -> Bool {
        await MainActor.run {
            let alert = NSAlert()
            alert.alertStyle = challenge.tier == .high ? .critical : .warning
            alert.messageText = "Approve this exact action?"
            alert.informativeText = NativeUISanitizer.escaped(
                summary,
                maximumInputUTF16: 2_000,
                maximumOutputUTF16: 4_096
            )
            alert.addButton(withTitle: "Approve Once")
            alert.addButton(withTitle: "Deny")
            return alert.runModal() == .alertFirstButtonReturn
        }
    }
}
