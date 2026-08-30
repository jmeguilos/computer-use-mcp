import Foundation

public enum RiskTier: String, Codable, Comparable, Sendable {
    case low
    case medium
    case high
    case blocked

    private var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        case .blocked: return 3
        }
    }

    public static func < (lhs: RiskTier, rhs: RiskTier) -> Bool { lhs.rank < rhs.rank }
}

public struct RiskChallenge: Codable, Equatable, Sendable {
    public let id: UUID
    public var approvalRequestID: UUID { id }
    public let connectionID: UUID
    public let requestID: String
    public let actionDigest: String
    public let tier: RiskTier
    public let approvalMode: ApprovalMode
    public let createdAt: Date
    public let expiresAt: Date

    public init(
        id: UUID = UUID(),
        connectionID: UUID,
        requestID: String,
        actionDigest: String,
        tier: RiskTier,
        approvalMode: ApprovalMode = .elicitation,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.connectionID = connectionID
        self.requestID = requestID
        self.actionDigest = actionDigest
        self.tier = tier
        self.approvalMode = approvalMode
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public enum RiskAuthorization: Equatable, Sendable {
    case authorized
    case challenge(RiskChallenge)
    case denied(String)
}

public enum RiskApprovalDisposition: String, Equatable, Sendable {
    case approved
    case denied
}

public enum RiskApprovalResolutionResult: Equatable, Sendable {
    case resolved(disposition: RiskApprovalDisposition, consumed: Bool)
    case decisionMismatch
    case unavailable
}

private struct RiskApprovalResolutionTombstone: Sendable {
    let connectionID: UUID
    let approved: Bool
    let approvalMode: ApprovalMode
    let expiresAt: Date
    var consumed: Bool
}

public actor RiskApprovalStore {
    private var pending: [UUID: RiskChallenge] = [:]
    private var approved: [UUID: RiskChallenge] = [:]
    private var resolutions: [UUID: RiskApprovalResolutionTombstone] = [:]
    private let challengeLifetime: TimeInterval

    public init(challengeLifetime: TimeInterval = 120) {
        self.challengeLifetime = challengeLifetime
    }

    public func authorize(
        connectionID: UUID,
        requestID: String,
        actionDigest: String,
        tier: RiskTier,
        approvalMode: ApprovalMode = .elicitation,
        now: Date = Date()
    ) -> RiskAuthorization {
        purgeExpired(now: now)
        if tier == .blocked { return .denied("risk_blocked") }
        if tier == .low { return .authorized }
        if let existing = pending.values.first(where: {
            $0.connectionID == connectionID && $0.actionDigest == actionDigest && $0.expiresAt > now
        }) {
            return .challenge(existing)
        }
        let challenge = RiskChallenge(
            connectionID: connectionID,
            requestID: requestID,
            actionDigest: actionDigest,
            tier: tier,
            approvalMode: approvalMode,
            createdAt: now,
            expiresAt: now.addingTimeInterval(challengeLifetime)
        )
        pending[challenge.id] = challenge
        return .challenge(challenge)
    }

    public func resolve(
        challengeID: UUID,
        connectionID: UUID,
        approved: Bool,
        approvalMode: ApprovalMode = .elicitation,
        now: Date = Date()
    ) -> RiskApprovalResolutionResult {
        purgeExpired(now: now)
        if let resolution = resolutions[challengeID] {
            guard resolution.connectionID == connectionID,
                  resolution.approvalMode == approvalMode,
                  resolution.expiresAt > now else {
                return .unavailable
            }
            guard resolution.approved == approved else { return .decisionMismatch }
            return .resolved(
                disposition: approved ? .approved : .denied,
                consumed: resolution.consumed
            )
        }

        guard let challenge = pending[challengeID],
              challenge.connectionID == connectionID,
              challenge.approvalMode == approvalMode,
              challenge.expiresAt > now else { return .unavailable }
        pending.removeValue(forKey: challengeID)
        resolutions[challengeID] = RiskApprovalResolutionTombstone(
            connectionID: challenge.connectionID,
            approved: approved,
            approvalMode: challenge.approvalMode,
            expiresAt: challenge.expiresAt,
            consumed: false
        )
        if approved {
            self.approved[challenge.id] = challenge
        }
        return .resolved(disposition: approved ? .approved : .denied, consumed: false)
    }

    public func consumeApproved(
        approvalRequestID: UUID,
        connectionID: UUID,
        actionDigest: String,
        approvalMode: ApprovalMode = .elicitation,
        now: Date = Date()
    ) -> Bool {
        purgeExpired(now: now)
        guard let challenge = approved.removeValue(forKey: approvalRequestID) else { return false }
        if var resolution = resolutions[approvalRequestID] {
            resolution.consumed = true
            resolutions[approvalRequestID] = resolution
        }
        guard challenge.connectionID == connectionID,
              challenge.actionDigest == actionDigest,
              challenge.approvalMode == approvalMode,
              challenge.expiresAt > now else { return false }
        return true
    }

    public func revoke(connectionID: UUID) {
        pending = pending.filter { $0.value.connectionID != connectionID }
        approved = approved.filter { $0.value.connectionID != connectionID }
        resolutions = resolutions.filter { $0.value.connectionID != connectionID }
    }

    public func revokeAll() {
        pending.removeAll()
        approved.removeAll()
        resolutions.removeAll()
    }

    public func pendingChallenges(connectionID: UUID, now: Date = Date()) -> [RiskChallenge] {
        purgeExpired(now: now)
        return pending.values.filter { $0.connectionID == connectionID }.sorted { $0.createdAt < $1.createdAt }
    }

    private func purgeExpired(now: Date) {
        pending = pending.filter { $0.value.expiresAt > now }
        approved = approved.filter { $0.value.expiresAt > now }
        resolutions = resolutions.filter { $0.value.expiresAt > now }
    }
}
