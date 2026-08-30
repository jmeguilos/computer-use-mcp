import ApplicationServices
import CoreGraphics
import Foundation

public enum PermissionState: String, Codable, Equatable, Sendable {
    case granted
    case denied
}

public struct PermissionSnapshot: Codable, Equatable, Sendable {
    public let screenCapture: PermissionState
    public let accessibility: PermissionState
    public let eventPosting: PermissionState
    public let eventListening: PermissionState

    public init(
        screenCapture: PermissionState,
        accessibility: PermissionState,
        eventPosting: PermissionState,
        eventListening: PermissionState
    ) {
        self.screenCapture = screenCapture
        self.accessibility = accessibility
        self.eventPosting = eventPosting
        self.eventListening = eventListening
    }

    public func permits(_ capability: HostCapability) -> Bool {
        switch capability {
        case .windowCapture, .displayCapture:
            return screenCapture == .granted
        case .accessibilityRead, .accessibilityAction:
            return accessibility == .granted
        case .syntheticInput:
            return accessibility == .granted && eventPosting == .granted
        case .inventoryRead, .indicatorControl, .riskApprove, .sessionStop:
            return true
        }
    }

    /// Input Monitoring is intentionally excluded. V1 does not observe global
    /// input, so readiness depends only on capture, Accessibility and posting.
    public var isReadyForInteractiveControl: Bool {
        screenCapture == .granted && accessibility == .granted && eventPosting == .granted
    }
}

public enum PermissionKind: String, Codable, CaseIterable, Sendable {
    case screenCapture
    case accessibility
    case eventPosting
    case eventListening
}

public protocol SystemPermissionChecking: Sendable {
    func snapshot() -> PermissionSnapshot
    @discardableResult func request(_ permission: PermissionKind) -> Bool
}

public struct MacSystemPermissionChecker: SystemPermissionChecking {
    public init() {}

    public func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            screenCapture: CGPreflightScreenCaptureAccess() ? .granted : .denied,
            accessibility: AXIsProcessTrusted() ? .granted : .denied,
            eventPosting: CGPreflightPostEventAccess() ? .granted : .denied,
            eventListening: CGPreflightListenEventAccess() ? .granted : .denied
        )
    }

    @discardableResult
    public func request(_ permission: PermissionKind) -> Bool {
        switch permission {
        case .screenCapture:
            return CGRequestScreenCaptureAccess()
        case .accessibility:
            let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(prompt)
        case .eventPosting:
            return CGRequestPostEventAccess()
        case .eventListening:
            // Optional diagnostic only. Never trigger this TCC prompt from v1.
            return CGPreflightListenEventAccess()
        }
    }
}
