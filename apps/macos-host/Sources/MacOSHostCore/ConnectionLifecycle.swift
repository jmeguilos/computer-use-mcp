import Foundation

public struct PeerIdentity: Codable, Equatable, Sendable {
    public let uid: UInt32
    public let processID: Int32
    public let name: String
    public let instanceID: String
    private enum CodingKeys: String, CodingKey {
        case uid
        case processID = "pid"
        case name
        case instanceID = "instanceId"
    }

    public init(uid: UInt32, processID: Int32, name: String, instanceID: String) {
        self.uid = uid
        self.processID = processID
        self.name = name
        self.instanceID = instanceID
    }
}

public struct ConnectionRecord: Codable, Equatable, Sendable {
    public let id: UUID
    /// A cryptographically random bearer capability that must accompany every
    /// post-handshake request. The UUID alone is never sufficient authority.
    public let capabilityToken: String
    public let peer: PeerIdentity
    public let capabilities: Set<HostCapability>
    public let openedAt: Date
    public var lastActivityAt: Date
    public let idleTimeout: TimeInterval
    private enum CodingKeys: String, CodingKey {
        case id, capabilityToken, peer, capabilities, openedAt, lastActivityAt, idleTimeout
    }

    public var idleExpiresAt: Date { lastActivityAt.addingTimeInterval(idleTimeout) }

    public func isExpired(at date: Date) -> Bool { date >= idleExpiresAt }
}

public enum ConnectionValidationError: String, Error, Equatable, Sendable {
    case peerUIDMismatch
    case peerPIDMismatch
    case incompatibleProtocol
    case unsupportedCapability
    case unauthenticated
    case expired
    case capabilityDenied
    case connectionTokenMismatch
}

public struct CapabilityNegotiator: Sendable {
    public let supported: Set<HostCapability>

    public init(supported: Set<HostCapability> = Set(HostCapability.allCases)) {
        self.supported = supported
    }

    public func negotiate(requested: Set<HostCapability>) throws -> Set<HostCapability> {
        let unsupported = requested.subtracting(supported)
        guard unsupported.isEmpty else { throw ConnectionValidationError.unsupportedCapability }
        return requested
    }
}

public actor ConnectionRegistry {
    private var records: [UUID: ConnectionRecord] = [:]
    private let idleTimeout: TimeInterval

    public init(idleTimeout: TimeInterval = 900) {
        self.idleTimeout = idleTimeout
    }

    public func open(
        peer: PeerIdentity,
        kernelUID: UInt32,
        kernelPID: Int32?,
        protocolVersion: ProtocolVersion,
        requestedCapabilities: Set<HostCapability>,
        capabilityToken: String,
        negotiator: CapabilityNegotiator = CapabilityNegotiator(),
        now: Date = Date()
    ) throws -> ConnectionRecord {
        guard peer.uid == kernelUID else { throw ConnectionValidationError.peerUIDMismatch }
        if let kernelPID, kernelPID > 0, peer.processID != kernelPID {
            throw ConnectionValidationError.peerPIDMismatch
        }
        guard ProtocolVersion.current.isCompatible(with: protocolVersion) else {
            throw ConnectionValidationError.incompatibleProtocol
        }
        let accepted = try negotiator.negotiate(requested: requestedCapabilities)
        guard capabilityToken.count >= 43 else { throw ConnectionValidationError.unauthenticated }
        let record = ConnectionRecord(
            id: UUID(),
            capabilityToken: capabilityToken,
            peer: peer,
            capabilities: accepted,
            openedAt: now,
            lastActivityAt: now,
            idleTimeout: idleTimeout
        )
        records[record.id] = record
        return record
    }

    @discardableResult
    public func touch(
        connectionID: UUID,
        capabilityToken: String,
        requiring capability: HostCapability? = nil,
        now: Date = Date()
    ) throws -> ConnectionRecord {
        guard var record = records[connectionID] else { throw ConnectionValidationError.unauthenticated }
        guard constantTimeEqual(record.capabilityToken, capabilityToken) else {
            throw ConnectionValidationError.connectionTokenMismatch
        }
        if record.isExpired(at: now) {
            records.removeValue(forKey: connectionID)
            throw ConnectionValidationError.expired
        }
        if let capability, !record.capabilities.contains(capability) {
            throw ConnectionValidationError.capabilityDenied
        }
        record.lastActivityAt = now
        records[connectionID] = record
        return record
    }

    public func close(connectionID: UUID) {
        records.removeValue(forKey: connectionID)
    }

    public func revokeExpired(now: Date = Date()) -> [UUID] {
        let expired = records.values.filter { $0.isExpired(at: now) }.map(\.id)
        for id in expired { records.removeValue(forKey: id) }
        return expired
    }

    public func record(connectionID: UUID) -> ConnectionRecord? { records[connectionID] }
}

private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8)
    let b = Array(rhs.utf8)
    let count = max(a.count, b.count)
    var difference = UInt8(truncatingIfNeeded: a.count ^ b.count)
    for index in 0..<count {
        let av = index < a.count ? a[index] : 0
        let bv = index < b.count ? b[index] : 0
        difference |= av ^ bv
    }
    return difference == 0
}
