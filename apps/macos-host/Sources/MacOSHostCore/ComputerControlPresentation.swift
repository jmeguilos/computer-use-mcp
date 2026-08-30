import Foundation

public enum ComputerControlPermissionKind: String, CaseIterable, Codable, Equatable, Sendable {
    case screenRecording
    case accessibility
}

public enum ComputerControlPermissionStatus: String, Codable, Equatable, Sendable {
    case ready
    case needsAccess
}

public struct ComputerControlPermissionRow: Codable, Equatable, Sendable {
    public let kind: ComputerControlPermissionKind
    public let status: ComputerControlPermissionStatus

    public init(kind: ComputerControlPermissionKind, status: ComputerControlPermissionStatus) {
        self.kind = kind
        self.status = status
    }
}

public enum ComputerControlAvailability: String, Codable, Equatable, Sendable {
    case disabled
    case needsSystemAccess
    case ready
}

public struct ComputerControlPresentation: Codable, Equatable, Sendable {
    public let availability: ComputerControlAvailability
    public let permissionRows: [ComputerControlPermissionRow]

    public init(permissions: PermissionSnapshot, anyAppControlEnabled: Bool) {
        let screenStatus: ComputerControlPermissionStatus = permissions.screenCapture == .granted
            ? .ready : .needsAccess
        // Event posting is part of the user-facing Accessibility capability.
        // Input Monitoring is intentionally absent because v1 never observes
        // global input and must not request or imply that permission.
        let accessibilityStatus: ComputerControlPermissionStatus =
            permissions.accessibility == .granted && permissions.eventPosting == .granted
                ? .ready : .needsAccess

        permissionRows = [
            ComputerControlPermissionRow(kind: .screenRecording, status: screenStatus),
            ComputerControlPermissionRow(kind: .accessibility, status: accessibilityStatus),
        ]

        if !anyAppControlEnabled {
            availability = .disabled
        } else if screenStatus != .ready || accessibilityStatus != .ready {
            availability = .needsSystemAccess
        } else {
            availability = .ready
        }
    }
}
