import Foundation

public struct ApplicationSelector: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case bundleID = "bundle_id"; case name; case path }
    public let kind: Kind
    public let value: String
    public init(kind: Kind, value: String) { self.kind = kind; self.value = value }
}

public enum AccessTargetRequest: Codable, Equatable, Sendable {
    case window(app: ApplicationSelector, windowHint: String?, launchIfNeeded: Bool)
    case display(displayID: String)

    private enum CodingKeys: String, CodingKey { case kind, app, windowHint, launchIfNeeded; case displayID = "displayId" }
    private enum Kind: String, Codable { case window, display }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .window:
            self = .window(
                app: try container.decode(ApplicationSelector.self, forKey: .app),
                windowHint: try container.decodeIfPresent(String.self, forKey: .windowHint),
                launchIfNeeded: try container.decodeIfPresent(Bool.self, forKey: .launchIfNeeded) ?? false
            )
        case .display:
            self = .display(displayID: try container.decode(String.self, forKey: .displayID))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .window(let app, let hint, let launch):
            try container.encode(Kind.window, forKey: .kind)
            try container.encode(app, forKey: .app)
            try container.encodeIfPresent(hint, forKey: .windowHint)
            try container.encode(launch, forKey: .launchIfNeeded)
        case .display(let displayID):
            try container.encode(Kind.display, forKey: .kind)
            try container.encode(displayID, forKey: .displayID)
        }
    }
}

public struct GrantReceipt: Codable, Equatable, Sendable {
    public let grantID: UUID
    public let persistence: GrantPersistence
    public let capabilities: Set<HostCapability>
    public let expiresAt: Date
    private enum CodingKeys: String, CodingKey {
        case grantID = "grantId"
        case persistence, capabilities, expiresAt
    }
}

public enum GrantStoreError: String, Error, Equatable, Sendable {
    case grantNotFound
    case grantConnectionMismatch
    case grantExpired
    case capabilityDenied
    case displayMustBeSessionOnly
    case targetLocked
}

public actor GrantStore {
    private var grants: [UUID: AccessGrant] = [:]
    private let idleTimeout: TimeInterval

    public init(idleTimeout: TimeInterval = 900) { self.idleTimeout = idleTimeout }

    public func issue(
        grantID: UUID = UUID(),
        connectionID: UUID,
        scope: GrantScope,
        capabilities: Set<HostCapability>,
        persistence: GrantPersistence,
        now: Date = Date(),
        lifetime: TimeInterval? = nil
    ) throws -> GrantReceipt {
        if case .display = scope, persistence != .sessionOnly {
            throw GrantStoreError.displayMustBeSessionOnly
        }
        let grant = try AccessGrant(
            id: grantID,
            connectionID: connectionID,
            scope: scope,
            capabilities: capabilities,
            persistence: persistence,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(lifetime ?? idleTimeout)
        )
        grants[grant.id] = grant
        return GrantReceipt(
            grantID: grant.id,
            persistence: grant.persistence,
            capabilities: grant.capabilities,
            expiresAt: grant.expiresAt
        )
    }

    public func authorize(
        grantID: UUID,
        connectionID: UUID,
        capability: HostCapability,
        now: Date = Date()
    ) throws -> AccessGrant {
        guard let grant = grants[grantID] else { throw GrantStoreError.grantNotFound }
        guard grant.connectionID == connectionID else { throw GrantStoreError.grantConnectionMismatch }
        // Expiry cleanup owns rail/lock/frame teardown in HostController.
        // Never delete lazily here and strand those associated resources.
        guard now < grant.expiresAt else { throw GrantStoreError.grantExpired }
        guard grant.capabilities.contains(capability) else { throw GrantStoreError.capabilityDenied }
        let refreshed = try AccessGrant(
            id: grant.id,
            connectionID: grant.connectionID,
            scope: grant.scope,
            capabilities: grant.capabilities,
            persistence: grant.persistence,
            issuedAt: grant.issuedAt,
            expiresAt: now.addingTimeInterval(idleTimeout)
        )
        grants[grantID] = refreshed
        return refreshed
    }

    public func release(grantID: UUID, connectionID: UUID) throws {
        guard let grant = grants[grantID] else { throw GrantStoreError.grantNotFound }
        guard grant.connectionID == connectionID else { throw GrantStoreError.grantConnectionMismatch }
        grants.removeValue(forKey: grantID)
    }

    @discardableResult
    public func revoke(connectionID: UUID) -> [UUID] {
        let identifiers = grants.values.filter { $0.connectionID == connectionID }.map(\.id)
        for identifier in identifiers { grants.removeValue(forKey: identifier) }
        return identifiers
    }

    @discardableResult
    public func revoke(grantID: UUID) -> AccessGrant? {
        grants.removeValue(forKey: grantID)
    }

    public func revokeAll() -> [UUID] {
        let identifiers = Array(grants.keys)
        grants.removeAll()
        return identifiers
    }

    public func revokeExpired(now: Date = Date()) -> [AccessGrant] {
        let expired = grants.values.filter { $0.expiresAt <= now }
        for grant in expired { grants.removeValue(forKey: grant.id) }
        return expired
    }

    public func active(connectionID: UUID, now: Date = Date()) -> [AccessGrant] {
        return grants.values.filter { $0.connectionID == connectionID && $0.expiresAt > now }
            .sorted { $0.issuedAt < $1.issuedAt }
    }
}

public struct FrameResource: Codable, Equatable, Sendable {
    public let frameID: UUID
    public let grantID: UUID
    public let connectionID: UUID
    public let transform: ScreenshotTransform
    public let createdAt: Date
    public let expiresAt: Date
    private enum CodingKeys: String, CodingKey {
        case frameID = "frameId"
        case grantID = "grantId"
        case connectionID = "connectionId"
        case transform, createdAt, expiresAt
    }
}

public enum FrameResourceError: String, Error, Equatable, Sendable {
    case frameNotFound
    case staleFrame
    case frameConnectionMismatch
    case frameGrantMismatch
    case intentRequired
}

public actor FrameResourceStore {
    private var resources: [UUID: FrameResource] = [:]
    private var currentByGrant: [UUID: UUID] = [:]
    private let lifetime: TimeInterval

    public init(lifetime: TimeInterval = 60) { self.lifetime = lifetime }

    public func create(
        grantID: UUID,
        connectionID: UUID,
        transform: ScreenshotTransform,
        now: Date = Date()
    ) -> FrameResource {
        if let previous = currentByGrant[grantID] { resources.removeValue(forKey: previous) }
        let resource = FrameResource(
            frameID: UUID(),
            grantID: grantID,
            connectionID: connectionID,
            transform: transform,
            createdAt: now,
            expiresAt: now.addingTimeInterval(lifetime)
        )
        resources[resource.frameID] = resource
        currentByGrant[grantID] = resource.frameID
        return resource
    }

    public func validate(
        frameID: UUID,
        grantID: UUID,
        connectionID: UUID,
        intent: String,
        now: Date = Date()
    ) throws -> FrameResource {
        guard !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, intent.count <= 512 else {
            throw FrameResourceError.intentRequired
        }
        guard let resource = resources[frameID] else { throw FrameResourceError.frameNotFound }
        guard resource.connectionID == connectionID else { throw FrameResourceError.frameConnectionMismatch }
        guard resource.grantID == grantID else { throw FrameResourceError.frameGrantMismatch }
        guard resource.expiresAt > now, currentByGrant[grantID] == frameID else {
            resources.removeValue(forKey: frameID)
            throw FrameResourceError.staleFrame
        }
        return resource
    }

    public func revoke(grantIDs: [UUID]) {
        for grantID in grantIDs {
            if let frameID = currentByGrant.removeValue(forKey: grantID) { resources.removeValue(forKey: frameID) }
        }
    }

    public func revoke(connectionID: UUID) {
        let frameIDs = resources.values.filter { $0.connectionID == connectionID }.map(\.frameID)
        let grantIDs = Set(frameIDs.compactMap { resources[$0]?.grantID })
        for frameID in frameIDs { resources.removeValue(forKey: frameID) }
        for grantID in grantIDs { currentByGrant.removeValue(forKey: grantID) }
    }

    public func revokeAll() {
        resources.removeAll()
        currentByGrant.removeAll()
    }
}

public actor ControllerLockStore {
    private struct Owner { let connectionID: UUID; let grantID: UUID }
    private var ownerByTarget: [String: Owner] = [:]

    public init() {}

    public func acquire(targetKey: String, connectionID: UUID, grantID: UUID) throws {
        if let owner = ownerByTarget[targetKey], owner.grantID != grantID {
            throw GrantStoreError.targetLocked
        }
        ownerByTarget[targetKey] = Owner(connectionID: connectionID, grantID: grantID)
    }

    public func release(grantID: UUID) {
        ownerByTarget = ownerByTarget.filter { $0.value.grantID != grantID }
    }

    public func revoke(connectionID: UUID) {
        ownerByTarget = ownerByTarget.filter { $0.value.connectionID != connectionID }
    }

    public func revokeAll() { ownerByTarget.removeAll() }
}

public actor ActionExecutionGate {
    private var activeGrantIDs: Set<UUID> = []

    public init() {}

    public func acquire(grantID: UUID) -> Bool {
        activeGrantIDs.insert(grantID).inserted
    }

    public func release(grantID: UUID) {
        activeGrantIDs.remove(grantID)
    }

    public func isActive(grantID: UUID) -> Bool { activeGrantIDs.contains(grantID) }
}
