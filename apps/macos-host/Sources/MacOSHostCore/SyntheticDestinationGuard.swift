import AppKit
import CoreGraphics
import Foundation

public enum SyntheticDestinationGuardError: String, Error, Equatable, Sendable {
    case exactWindowUnavailable
    case identityChanged
    case protectedSurface
    case unrelatedOccluder
    case exactWindowRequired
    case pointOutsideTarget
    case selfControlBlocked
}

public struct WindowStackEntry: Equatable, Sendable {
    public let windowID: UInt32
    public let processID: Int32
    public let bundleIdentifier: String
    public let processName: String
    public let title: String?
    public let frame: Rect
    public let layer: Int
    public let alpha: Double

    public init(
        windowID: UInt32,
        processID: Int32,
        bundleIdentifier: String,
        processName: String,
        title: String? = nil,
        frame: Rect,
        layer: Int,
        alpha: Double
    ) {
        self.windowID = windowID
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.processName = processName
        self.title = title
        self.frame = frame
        self.layer = layer
        self.alpha = alpha
    }
}

/// Narrow host-facing seam. Production uses the live Quartz-backed guard;
/// tests inject a deterministic validator so approval/dispatch behavior can be
/// exercised without reading the real desktop window stack.
public protocol SyntheticDestinationGuarding: Sendable {
    func validate(
        scope: GrantScope,
        globalPoints: [Point],
        requireWholeTarget: Bool,
        excludingProcess: CaptureExcludedProcessIdentity?
    ) throws
    func validateSemanticWindow(_ identity: WindowIdentity) throws
}

/// Re-checks the live front-to-back Quartz stack immediately before public
/// CGEvent fallback. This prevents an omitted authorization sheet or unrelated
/// overlay from receiving an event intended for the captured target.
public struct SyntheticDestinationGuard: Sendable {
    private let protectedPolicy: ProtectedProcessPolicy

    public init(protectedPolicy: ProtectedProcessPolicy = ProtectedProcessPolicy()) {
        self.protectedPolicy = protectedPolicy
    }

    public func validate(
        scope: GrantScope,
        globalPoints: [Point],
        requireWholeTarget: Bool,
        excludingProcess: CaptureExcludedProcessIdentity? = nil,
        stack suppliedStack: [WindowStackEntry]? = nil
    ) throws {
        let stack = suppliedStack ?? Self.currentStack()
        switch scope {
        case .window(let identity):
            try validateWindow(
                identity,
                stack: stack,
                globalPoints: globalPoints,
                requireWholeTarget: requireWholeTarget
            )
        case .display(let display):
            if globalPoints.isEmpty {
                try validateFocusedWindow(
                    on: display,
                    stack: stack,
                    excludingProcess: excludingProcess
                )
                return
            }
            for point in globalPoints {
                if stack.contains(where: {
                    $0.alpha > 0.01 && $0.frame.cgRect.contains(point.cgPoint) &&
                        Self.matches($0, exclusion: excludingProcess)
                }) {
                    throw SyntheticDestinationGuardError.selfControlBlocked
                }
                if stack.contains(where: {
                    $0.alpha > 0.01 && $0.frame.cgRect.contains(point.cgPoint) && isProtected($0)
                }) {
                    throw SyntheticDestinationGuardError.protectedSurface
                }
                guard let destination = stack.first(where: {
                    $0.layer == 0 && $0.alpha > 0.01 && $0.frame.cgRect.contains(point.cgPoint)
                }) else { continue }
                guard !Self.matches(destination, exclusion: excludingProcess) else {
                    throw SyntheticDestinationGuardError.selfControlBlocked
                }
                guard !isProtected(destination) else { throw SyntheticDestinationGuardError.protectedSurface }
            }
        }
    }

    public func validateFocusedWindow(
        on display: DisplayIdentity,
        stack: [WindowStackEntry]? = nil,
        excludingProcess: CaptureExcludedProcessIdentity? = nil
    ) throws {
        guard let application = NSWorkspace.shared.frontmostApplication,
              !application.isTerminated,
              let bundleIdentifier = application.bundleIdentifier else {
            throw SyntheticDestinationGuardError.exactWindowRequired
        }
        let processID = application.processIdentifier
        try validateFocusedApplication(
            processID: processID,
            bundleIdentifier: bundleIdentifier,
            excludingProcess: excludingProcess
        )
        guard protectedPolicy.evaluate(
            bundleIdentifier: bundleIdentifier,
            processName: application.localizedName ?? "",
            processID: processID
        ).allowed else { throw SyntheticDestinationGuardError.protectedSurface }
        let axApplication = AXUIElementCreateApplication(processID)
        guard let focusedValue = AXHelpers.copyAttribute(axApplication, kAXFocusedWindowAttribute),
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            throw SyntheticDestinationGuardError.exactWindowRequired
        }
        let focused = unsafeBitCast(focusedValue, to: AXUIElement.self)
        guard let position = AXHelpers.pointAttribute(focused, kAXPositionAttribute),
              let size = AXHelpers.sizeAttribute(focused, kAXSizeAttribute),
              size.width > 0, size.height > 0 else {
            throw SyntheticDestinationGuardError.exactWindowRequired
        }
        let focusedFrame = CGRect(origin: position, size: size)
        let intersection = focusedFrame.intersection(display.frame.cgRect)
        guard !intersection.isNull,
              intersection.width * intersection.height >= focusedFrame.width * focusedFrame.height * 0.5 else {
            throw SyntheticDestinationGuardError.exactWindowRequired
        }
        let resolved = stack ?? Self.currentStack()
        guard let top = resolved.first(where: {
            $0.processID == processID && Self.framesApproximatelyEqual($0.frame.cgRect, focusedFrame)
        }), !Self.matches(top, exclusion: excludingProcess), !isProtected(top) else {
            throw SyntheticDestinationGuardError.protectedSurface
        }
    }

    public func validateFocusedApplication(
        processID: Int32,
        bundleIdentifier: String,
        excludingProcess: CaptureExcludedProcessIdentity?
    ) throws {
        guard let exclusion = excludingProcess else { return }
        guard processID != exclusion.processID || bundleIdentifier != exclusion.bundleIdentifier else {
            throw SyntheticDestinationGuardError.selfControlBlocked
        }
    }

    public func validateWindow(
        _ identity: WindowIdentity,
        stack: [WindowStackEntry],
        globalPoints: [Point],
        requireWholeTarget: Bool
    ) throws {
        guard let targetIndex = stack.firstIndex(where: { $0.windowID == identity.windowID }) else {
            throw SyntheticDestinationGuardError.exactWindowUnavailable
        }
        let target = stack[targetIndex]
        let running = NSRunningApplication(processIdentifier: identity.processID)
        let processStart = running?.launchDate.map { Int64($0.timeIntervalSince1970 * 1_000) }
        guard target.processID == identity.processID,
              target.bundleIdentifier == identity.bundleIdentifier,
              running?.bundleIdentifier == identity.bundleIdentifier,
              processStart == identity.processStartTimeUnixMs,
              ProcessCodeIdentity.designatedRequirementDigest(processID: identity.processID) == identity.signingIdentity else {
            throw SyntheticDestinationGuardError.identityChanged
        }
        guard !isProtected(target) else { throw SyntheticDestinationGuardError.protectedSurface }
        guard globalPoints.allSatisfy({ target.frame.cgRect.contains($0.cgPoint) }) else {
            throw SyntheticDestinationGuardError.pointOutsideTarget
        }

        if let blocking = blockingOccluder(
            targetIndex: targetIndex,
            stack: stack,
            globalPoints: globalPoints,
            requireWholeTarget: requireWholeTarget
        ) { throw blocking }
    }

    /// AX actions may intentionally remain in the background, but they still
    /// fail closed when a live authorization/security surface is above the
    /// granted window. Unlike CGEvent validation, unrelated ordinary windows
    /// do not prevent semantic AX dispatch.
    public func validateSemanticWindow(
        _ identity: WindowIdentity,
        stack: [WindowStackEntry]? = nil
    ) throws {
        let resolved = stack ?? Self.currentStack()
        try validateWindow(
            identity,
            stack: resolved,
            globalPoints: [],
            requireWholeTarget: false
        )
        guard let targetIndex = resolved.firstIndex(where: { $0.windowID == identity.windowID }) else {
            throw SyntheticDestinationGuardError.exactWindowUnavailable
        }
        if blockingProtectedOverlay(targetIndex: targetIndex, stack: resolved) {
            throw SyntheticDestinationGuardError.protectedSurface
        }
    }

    public func blockingProtectedOverlay(targetIndex: Int, stack: [WindowStackEntry]) -> Bool {
        guard stack.indices.contains(targetIndex) else { return true }
        let target = stack[targetIndex]
        return stack[..<targetIndex].contains { entry in
            entry.alpha > 0.01 && entry.frame.cgRect.intersects(target.frame.cgRect) && isProtected(entry)
        }
    }

    public func blockingOccluder(
        targetIndex: Int,
        stack: [WindowStackEntry],
        globalPoints: [Point],
        requireWholeTarget: Bool
    ) -> SyntheticDestinationGuardError? {
        guard stack.indices.contains(targetIndex) else { return .exactWindowUnavailable }
        let target = stack[targetIndex]
        for entry in stack[..<targetIndex] where entry.alpha > 0.01 {
            let intersectsPoint = globalPoints.contains { entry.frame.cgRect.contains($0.cgPoint) }
            let intersectsTarget = requireWholeTarget && entry.frame.cgRect.intersects(target.frame.cgRect)
            guard !intersectsPoint && !intersectsTarget else {
                if isProtected(entry) {
                    return .protectedSurface
                }
                // A point event is delivered to the frontmost receiving
                // surface at that coordinate, regardless of its WindowServer
                // layer. A different elevated window (including another
                // window owned by the granted app) is therefore an unrelated
                // destination and must fail closed. Keep the layer-zero rule
                // for whole-target checks, whose synthetic key destination is
                // separately bound to the exact focused AX window.
                if intersectsPoint { return .unrelatedOccluder }
                if entry.layer != 0 { continue }
                return .unrelatedOccluder
            }
        }
        return nil
    }

    private func isProtected(_ entry: WindowStackEntry) -> Bool {
        !protectedPolicy.evaluateSurface(
            bundleIdentifier: entry.bundleIdentifier,
            processName: entry.processName,
            processID: entry.processID,
            title: entry.title
        ).allowed
    }

    public static func currentStack() -> [WindowStackEntry] {
        guard let values = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return values.compactMap { value in
            guard let windowID = (value[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let processID = (value[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bounds = value[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 0, frame.height > 0 else { return nil }
            let running = NSRunningApplication(processIdentifier: processID)
            return WindowStackEntry(
                windowID: windowID,
                processID: processID,
                bundleIdentifier: running?.bundleIdentifier ?? "",
                processName: value[kCGWindowOwnerName as String] as? String ?? running?.localizedName ?? "",
                title: value[kCGWindowName as String] as? String,
                frame: Rect(frame),
                layer: (value[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                alpha: (value[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            )
        }
    }

    private static func framesApproximatelyEqual(_ left: CGRect, _ right: CGRect) -> Bool {
        abs(left.minX - right.minX) <= 2 && abs(left.minY - right.minY) <= 2 &&
            abs(left.width - right.width) <= 2 && abs(left.height - right.height) <= 2
    }

    private static func matches(
        _ entry: WindowStackEntry,
        exclusion: CaptureExcludedProcessIdentity?
    ) -> Bool {
        guard let exclusion else { return false }
        return entry.processID == exclusion.processID &&
            entry.bundleIdentifier == exclusion.bundleIdentifier
    }
}

extension SyntheticDestinationGuard: SyntheticDestinationGuarding {
    public func validate(
        scope: GrantScope,
        globalPoints: [Point],
        requireWholeTarget: Bool,
        excludingProcess: CaptureExcludedProcessIdentity?
    ) throws {
        try validate(
            scope: scope,
            globalPoints: globalPoints,
            requireWholeTarget: requireWholeTarget,
            excludingProcess: excludingProcess,
            stack: nil
        )
    }

    public func validateSemanticWindow(_ identity: WindowIdentity) throws {
        try validateSemanticWindow(identity, stack: nil)
    }
}
