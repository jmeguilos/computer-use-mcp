import CoreGraphics
import Foundation

public struct ProtocolVersion: Codable, Equatable, Hashable, Sendable {
    public static let current = ProtocolVersion(major: 2, minor: 0)

    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public func isCompatible(with peer: ProtocolVersion) -> Bool {
        major == peer.major && peer.minor <= minor
    }
}

public enum HostCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case inventoryRead = "inventory.read"
    case windowCapture = "window.capture"
    case displayCapture = "display.capture"
    case accessibilityRead = "accessibility.read"
    case accessibilityAction = "accessibility.action"
    case syntheticInput = "input.synthetic"
    case indicatorControl = "indicator.control"
    case riskApprove = "risk.approve"
    case sessionStop = "session.stop"
}

public struct Point: Codable, Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(_ point: CGPoint) {
        self.init(x: point.x, y: point.y)
    }

    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

public struct Size: Codable, Equatable, Hashable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public init(_ size: CGSize) {
        self.init(width: size.width, height: size.height)
    }

    public var cgSize: CGSize { CGSize(width: width, height: height) }
}

public struct Rect: Codable, Equatable, Hashable, Sendable {
    public let origin: Point
    public let size: Size

    public init(origin: Point, size: Size) {
        self.origin = origin
        self.size = size
    }

    public init(_ rect: CGRect) {
        self.init(origin: Point(rect.origin), size: Size(rect.size))
    }

    public var cgRect: CGRect { CGRect(origin: origin.cgPoint, size: size.cgSize) }
}

public struct WindowIdentity: Codable, Equatable, Hashable, Sendable {
    public let windowID: UInt32
    public let processID: Int32
    public let bundleIdentifier: String
    public let ownerName: String
    public let signingIdentity: String
    public let processStartTimeUnixMs: Int64
    private enum CodingKeys: String, CodingKey {
        case windowID = "windowId"
        case processID = "processId"
        case bundleIdentifier, ownerName, signingIdentity, processStartTimeUnixMs
    }

    public init(
        windowID: UInt32,
        processID: Int32,
        bundleIdentifier: String,
        ownerName: String,
        signingIdentity: String,
        processStartTimeUnixMs: Int64
    ) throws {
        guard windowID != 0 else { throw ModelValidationError.invalidWindowID }
        guard processID > 1 else { throw ModelValidationError.invalidProcessID }
        guard !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelValidationError.missingBundleIdentifier
        }
        guard !signingIdentity.isEmpty else { throw ModelValidationError.missingSigningIdentity }
        guard processStartTimeUnixMs > 0 else { throw ModelValidationError.invalidProcessID }
        self.windowID = windowID
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.ownerName = ownerName
        self.signingIdentity = signingIdentity
        self.processStartTimeUnixMs = processStartTimeUnixMs
    }
}

public struct WindowDescriptor: Codable, Equatable, Sendable {
    public let identity: WindowIdentity
    public let title: String?
    public let frame: Rect
    public let layer: Int
    public let isOnScreen: Bool
    public let isActive: Bool

    public init(
        identity: WindowIdentity,
        title: String?,
        frame: Rect,
        layer: Int,
        isOnScreen: Bool,
        isActive: Bool
    ) throws {
        guard frame.size.width > 0, frame.size.height > 0 else { throw ModelValidationError.invalidBounds }
        self.identity = identity
        self.title = title
        self.frame = frame
        self.layer = layer
        self.isOnScreen = isOnScreen
        self.isActive = isActive
    }
}

public struct DisplayIdentity: Codable, Equatable, Hashable, Sendable {
    public let displayID: UInt32
    public let frame: Rect
    public let logicalSize: Size
    public let pixelSize: Size
    public let pointPixelScaleX: Double
    public let pointPixelScaleY: Double
    public let pointPixelScale: Double
    public let name: String
    public let isMain: Bool
    public let isMirrored: Bool
    private enum CodingKeys: String, CodingKey {
        case displayID = "displayId"
        case frame, logicalSize, pixelSize, pointPixelScaleX, pointPixelScaleY, pointPixelScale
        case name, isMain, isMirrored
    }

    public init(
        displayID: UInt32,
        frame: Rect,
        logicalSize: Size,
        pixelSize: Size,
        pointPixelScale: Double? = nil,
        pointPixelScaleX: Double? = nil,
        pointPixelScaleY: Double? = nil,
        name: String? = nil,
        isMain: Bool = false,
        isMirrored: Bool = false
    ) throws {
        guard displayID != 0 else { throw ModelValidationError.invalidDisplayID }
        guard logicalSize.width > 0, logicalSize.height > 0,
              pixelSize.width > 0, pixelSize.height > 0,
              (pointPixelScale ?? pointPixelScaleX ?? 0) > 0,
              (pointPixelScale ?? pointPixelScaleY ?? 0) > 0 else {
            throw ModelValidationError.invalidBounds
        }
        self.displayID = displayID
        self.frame = frame
        self.logicalSize = logicalSize
        self.pixelSize = pixelSize
        self.pointPixelScaleX = pointPixelScaleX ?? pointPixelScale!
        self.pointPixelScaleY = pointPixelScaleY ?? pointPixelScale!
        self.pointPixelScale = pointPixelScale ?? max(self.pointPixelScaleX, self.pointPixelScaleY)
        self.name = name ?? "Display \(displayID)"
        self.isMain = isMain
        self.isMirrored = isMirrored
    }
}

public enum GrantScope: Codable, Equatable, Hashable, Sendable {
    case window(WindowIdentity)
    case display(DisplayIdentity)

    private enum CodingKeys: String, CodingKey { case kind, window, display }
    private enum Kind: String, Codable { case window, display }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .window:
            self = .window(try container.decode(WindowIdentity.self, forKey: .window))
        case .display:
            self = .display(try container.decode(DisplayIdentity.self, forKey: .display))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .window(let window):
            try container.encode(Kind.window, forKey: .kind)
            try container.encode(window, forKey: .window)
        case .display(let display):
            try container.encode(Kind.display, forKey: .kind)
            try container.encode(display, forKey: .display)
        }
    }
}

public enum GrantPersistence: String, Codable, Equatable, Hashable, Sendable {
    case allowOnce
    case alwaysAllowApp
    case sessionOnly
}

public struct AccessGrant: Codable, Equatable, Sendable {
    public let id: UUID
    public let connectionID: UUID
    public let scope: GrantScope
    public let capabilities: Set<HostCapability>
    public let persistence: GrantPersistence
    public let issuedAt: Date
    public let expiresAt: Date
    private enum CodingKeys: String, CodingKey {
        case id
        case connectionID = "connectionId"
        case scope, capabilities, persistence, issuedAt, expiresAt
    }

    public init(
        id: UUID = UUID(),
        connectionID: UUID,
        scope: GrantScope,
        capabilities: Set<HostCapability>,
        persistence: GrantPersistence,
        issuedAt: Date,
        expiresAt: Date
    ) throws {
        guard !capabilities.isEmpty else { throw ModelValidationError.emptyCapabilities }
        guard expiresAt > issuedAt else { throw ModelValidationError.invalidExpiry }
        switch scope {
        case .window:
            guard !capabilities.contains(.displayCapture) else { throw ModelValidationError.scopeCapabilityMismatch }
        case .display:
            let windowOnly: Set<HostCapability> = [.windowCapture, .accessibilityRead, .accessibilityAction]
            guard capabilities.isDisjoint(with: windowOnly) else { throw ModelValidationError.scopeCapabilityMismatch }
            guard persistence == .sessionOnly else { throw ModelValidationError.scopePersistenceMismatch }
        }
        self.id = id
        self.connectionID = connectionID
        self.scope = scope
        self.capabilities = capabilities
        self.persistence = persistence
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    public func authorizes(_ capability: HostCapability, at date: Date) -> Bool {
        date < expiresAt && capabilities.contains(capability)
    }
}

public enum ModelValidationError: String, Error, Codable, Equatable, Sendable {
    case invalidWindowID
    case invalidDisplayID
    case invalidProcessID
    case missingBundleIdentifier
    case missingSigningIdentity
    case invalidBounds
    case emptyCapabilities
    case invalidExpiry
    case scopeCapabilityMismatch
    case scopePersistenceMismatch
}
