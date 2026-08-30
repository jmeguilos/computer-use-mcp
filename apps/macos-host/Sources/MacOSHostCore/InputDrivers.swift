import CoreGraphics
import Foundation

public enum MouseButton: String, Codable, Sendable {
    case left
    case right
    case center

    var cgButton: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .center: return .center
        }
    }
}

public enum InputDriverError: String, Error, Codable, Equatable, Sendable {
    case permissionDenied
    case invalidClickCount
    case invalidDuration
    case eventCreationFailed
    case canceled
    case deadlineExceeded
    case privateDriverDisabled
    case unsupportedOSVersion
    case implementationUnavailable
}

public protocol InteractionCancellationChecking: Sendable {
    func check() throws
}

public struct NeverCanceled: InteractionCancellationChecking {
    public init() {}
    public func check() throws {
        if Task.isCancelled { throw InputDriverError.canceled }
    }
}

/// Adds an absolute request deadline to any connection/grant cancellation
/// scope. Detached input tasks do not inherit actor task cancellation, so the
/// deadline must travel with the explicit cancellation object checked between
/// every bounded input step.
public struct DeadlineInteractionCancellation: InteractionCancellationChecking {
    private let base: any InteractionCancellationChecking
    private let deadline: Date

    public init(base: any InteractionCancellationChecking, deadline: Date) {
        self.base = base
        self.deadline = deadline
    }

    public func check() throws {
        try base.check()
        guard Date() < deadline else { throw InputDriverError.deadlineExceeded }
    }
}

/// Relays cancellation from the socket request task into detached, bounded
/// CoreGraphics work. `Task.detached` intentionally does not inherit the
/// parent's cancellation bit, so relying on `Task.isCancelled` there would let
/// an already-cancelled request continue posting events.
public final class RelayedInteractionCancellation: InteractionCancellationChecking, @unchecked Sendable {
    private let base: any InteractionCancellationChecking
    private let lock = NSLock()
    private var canceled = false

    public init(base: any InteractionCancellationChecking) { self.base = base }

    public func cancel() { lock.withLock { canceled = true } }

    public func check() throws {
        guard !lock.withLock({ canceled }) else { throw InputDriverError.canceled }
        try base.check()
    }
}

public final class InteractionStopToken: @unchecked Sendable {
    private let lock = NSLock()
    private var globalGeneration: UInt64 = 0
    private var connectionGenerations: [UUID: UInt64] = [:]
    private var grantGenerations: [UUID: UInt64] = [:]

    public init() {}

    public func scope(connectionID: UUID, grantID: UUID? = nil) -> InteractionCancellationChecking {
        let captured = lock.withLock {
            (
                globalGeneration,
                connectionGenerations[connectionID, default: 0],
                grantID.map { grantGenerations[$0, default: 0] } ?? 0
            )
        }
        return GenerationCancellationScope(
            coordinator: self,
            connectionID: connectionID,
            globalGeneration: captured.0,
            connectionGeneration: captured.1,
            grantID: grantID,
            grantGeneration: captured.2
        )
    }

    /// Cancels only work already running for one bridge connection. New work
    /// receives the next generation and is not affected.
    public func stop(connectionID: UUID) {
        lock.withLock { connectionGenerations[connectionID, default: 0] &+= 1 }
    }

    public func stop(grantID: UUID) {
        lock.withLock { grantGenerations[grantID, default: 0] &+= 1 }
    }

    /// Emergency Stop cancels every operation that already captured a scope.
    /// It never needs a reset, so an old operation cannot resume after cleanup.
    public func stopAll() { lock.withLock { globalGeneration &+= 1 } }

    fileprivate func check(
        connectionID: UUID,
        globalGeneration: UInt64,
        connectionGeneration: UInt64,
        grantID: UUID?,
        grantGeneration: UInt64
    ) throws {
        let unchanged = lock.withLock {
            self.globalGeneration == globalGeneration &&
                connectionGenerations[connectionID, default: 0] == connectionGeneration &&
                (grantID == nil || grantGenerations[grantID!, default: 0] == grantGeneration)
        }
        if !unchanged || Task.isCancelled { throw InputDriverError.canceled }
    }
}

private struct GenerationCancellationScope: InteractionCancellationChecking {
    let coordinator: InteractionStopToken
    let connectionID: UUID
    let globalGeneration: UInt64
    let connectionGeneration: UInt64
    let grantID: UUID?
    let grantGeneration: UInt64

    func check() throws {
        try coordinator.check(
            connectionID: connectionID,
            globalGeneration: globalGeneration,
            connectionGeneration: connectionGeneration,
            grantID: grantID,
            grantGeneration: grantGeneration
        )
    }
}

public protocol SyntheticInputDriving: Sendable {
    func click(globalPoint: Point, button: MouseButton, clickCount: Int, cancellation: InteractionCancellationChecking) throws
    func drag(from: Point, to: Point, button: MouseButton, duration: TimeInterval, cancellation: InteractionCancellationChecking) throws
    func typeText(_ text: String, cancellation: InteractionCancellationChecking) throws
    func key(code: UInt16, flags: UInt64, cancellation: InteractionCancellationChecking) throws
    func scroll(deltaX: Int32, deltaY: Int32, at globalPoint: Point?, cancellation: InteractionCancellationChecking) throws
}

public extension SyntheticInputDriving {
    func click(globalPoint: Point, button: MouseButton, clickCount: Int) throws {
        try click(globalPoint: globalPoint, button: button, clickCount: clickCount, cancellation: NeverCanceled())
    }
    func drag(from: Point, to: Point, button: MouseButton, duration: TimeInterval) throws {
        try drag(from: from, to: to, button: button, duration: duration, cancellation: NeverCanceled())
    }
    func typeText(_ text: String) throws { try typeText(text, cancellation: NeverCanceled()) }
    func key(code: UInt16, flags: UInt64) throws { try key(code: code, flags: flags, cancellation: NeverCanceled()) }
    func scroll(deltaX: Int32, deltaY: Int32, at globalPoint: Point? = nil) throws {
        try scroll(deltaX: deltaX, deltaY: deltaY, at: globalPoint, cancellation: NeverCanceled())
    }
}

public enum DeterministicInputPlan {
    public static func dragPoints(from: Point, to: Point, duration: TimeInterval, hertz: Double = 60) throws -> [Point] {
        guard duration.isFinite, duration >= 0, hertz.isFinite, hertz > 0 else {
            throw InputDriverError.invalidDuration
        }
        let steps = max(1, Int(ceil(duration * hertz)))
        return (0...steps).map { step in
            let fraction = Double(step) / Double(steps)
            return Point(
                x: from.x + (to.x - from.x) * fraction,
                y: from.y + (to.y - from.y) * fraction
            )
        }
    }

    public static func unicodeChunks(_ text: String, maximumScalars: Int = 20) -> [String] {
        guard maximumScalars > 0 else { return [] }
        var result: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            current.append(scalar)
            if current.count == maximumScalars {
                result.append(String(current))
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty { result.append(String(current)) }
        return result
    }
}

public struct CGEventInputDriver: SyntheticInputDriving {
    private let permissionChecker: SystemPermissionChecking

    public init(permissionChecker: SystemPermissionChecking = MacSystemPermissionChecker()) {
        self.permissionChecker = permissionChecker
    }

    public func click(
        globalPoint: Point,
        button: MouseButton = .left,
        clickCount: Int = 1,
        cancellation: InteractionCancellationChecking
    ) throws {
        try requirePermission()
        try cancellation.check()
        guard (1...3).contains(clickCount) else { throw InputDriverError.invalidClickCount }
        let types = mouseTypes(button)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: types.down, mouseCursorPosition: globalPoint.cgPoint, mouseButton: button.cgButton),
              let up = CGEvent(mouseEventSource: nil, mouseType: types.up, mouseCursorPosition: globalPoint.cgPoint, mouseButton: button.cgButton) else {
            throw InputDriverError.eventCreationFailed
        }
        down.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        up.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    public func drag(
        from: Point,
        to: Point,
        button: MouseButton = .left,
        duration: TimeInterval = 0.2,
        cancellation: InteractionCancellationChecking
    ) throws {
        try requirePermission()
        let points = try DeterministicInputPlan.dragPoints(from: from, to: to, duration: duration)
        let types = mouseTypes(button)
        try cancellation.check()
        guard let down = CGEvent(mouseEventSource: nil, mouseType: types.down, mouseCursorPosition: from.cgPoint, mouseButton: button.cgButton) else {
            throw InputDriverError.eventCreationFailed
        }
        down.post(tap: .cgSessionEventTap)
        var currentPoint = from
        do {
            let interval = points.count > 1 ? duration / Double(points.count - 1) : 0
            for point in points.dropFirst() {
                try cancellation.check()
                guard let moved = CGEvent(mouseEventSource: nil, mouseType: types.drag, mouseCursorPosition: point.cgPoint, mouseButton: button.cgButton) else {
                    throw InputDriverError.eventCreationFailed
                }
                moved.post(tap: .cgSessionEventTap)
                currentPoint = point
                if interval > 0 { Thread.sleep(forTimeInterval: interval) }
            }
            try cancellation.check()
            guard let up = CGEvent(mouseEventSource: nil, mouseType: types.up, mouseCursorPosition: to.cgPoint, mouseButton: button.cgButton) else {
                throw InputDriverError.eventCreationFailed
            }
            up.post(tap: .cgSessionEventTap)
        } catch {
            // Once mouse-down has posted, cancellation and every failure path
            // must best-effort balance it to avoid leaving macOS in a drag.
            CGEvent(
                mouseEventSource: nil,
                mouseType: types.up,
                mouseCursorPosition: currentPoint.cgPoint,
                mouseButton: button.cgButton
            )?.post(tap: .cgSessionEventTap)
            throw error
        }
    }

    public func typeText(_ text: String, cancellation: InteractionCancellationChecking) throws {
        try requirePermission()
        for chunk in DeterministicInputPlan.unicodeChunks(text) {
            try cancellation.check()
            let utf16 = chunk.utf16.map { UniChar($0) }
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw InputDriverError.eventCreationFailed
            }
            utf16.withUnsafeBufferPointer { pointer in
                down.keyboardSetUnicodeString(stringLength: pointer.count, unicodeString: pointer.baseAddress!)
                up.keyboardSetUnicodeString(stringLength: pointer.count, unicodeString: pointer.baseAddress!)
            }
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
        }
    }

    public func key(code: UInt16, flags: UInt64 = 0, cancellation: InteractionCancellationChecking) throws {
        try requirePermission()
        try cancellation.check()
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: false) else {
            throw InputDriverError.eventCreationFailed
        }
        down.flags = CGEventFlags(rawValue: flags)
        up.flags = CGEventFlags(rawValue: flags)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    public func scroll(
        deltaX: Int32,
        deltaY: Int32,
        at globalPoint: Point?,
        cancellation: InteractionCancellationChecking
    ) throws {
        try requirePermission()
        try cancellation.check()
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else { throw InputDriverError.eventCreationFailed }
        if let globalPoint { event.location = globalPoint.cgPoint }
        event.post(tap: .cgSessionEventTap)
    }

    private func requirePermission() throws {
        guard permissionChecker.snapshot().eventPosting == .granted else { throw InputDriverError.permissionDenied }
    }

    private func mouseTypes(_ button: MouseButton) -> (down: CGEventType, drag: CGEventType, up: CGEventType) {
        switch button {
        case .left: return (.leftMouseDown, .leftMouseDragged, .leftMouseUp)
        case .right: return (.rightMouseDown, .rightMouseDragged, .rightMouseUp)
        case .center: return (.otherMouseDown, .otherMouseDragged, .otherMouseUp)
        }
    }
}

public struct PrivateClickDriverConfiguration: Equatable, Sendable {
    public let explicitlyEnabled: Bool
    public let supportedMajorVersion: Int
    public let supportedMinorRange: Range<Int>

    public init(explicitlyEnabled: Bool, supportedMajorVersion: Int = 14, supportedMinorRange: Range<Int> = 4..<5) {
        self.explicitlyEnabled = explicitlyEnabled
        self.supportedMajorVersion = supportedMajorVersion
        self.supportedMinorRange = supportedMinorRange
    }
}

/// Deliberately contains no private API calls. The opt-in and version gates are
/// observable, but the unavailable implementation always fails closed.
public struct UnavailablePrivateClickDriver: Sendable {
    public let configuration: PrivateClickDriverConfiguration
    public let operatingSystemVersion: OperatingSystemVersion

    public init(
        configuration: PrivateClickDriverConfiguration,
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) {
        self.configuration = configuration
        self.operatingSystemVersion = operatingSystemVersion
    }

    public func click(window: WindowIdentity, localPoint: Point) throws {
        guard configuration.explicitlyEnabled else { throw InputDriverError.privateDriverDisabled }
        guard operatingSystemVersion.majorVersion == configuration.supportedMajorVersion,
              configuration.supportedMinorRange.contains(operatingSystemVersion.minorVersion) else {
            throw InputDriverError.unsupportedOSVersion
        }
        throw InputDriverError.implementationUnavailable
    }
}
