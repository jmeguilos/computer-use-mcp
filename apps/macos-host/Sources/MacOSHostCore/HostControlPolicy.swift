import Foundation

/// Security-sensitive global gate owned by the native host. Status and Stop
/// remain available while disabled; every operation that can expose or mutate
/// another app checks this policy at the point of use.
public protocol HostControlPolicyChecking: Sendable {
    func isAppControlEnabled() async -> Bool
}

public struct AlwaysEnabledHostControlPolicy: HostControlPolicyChecking {
    public init() {}
    public func isAppControlEnabled() async -> Bool { true }
}

extension PersistentHostPreferencesStore: HostControlPolicyChecking {
    public func isAppControlEnabled() async -> Bool {
        preferencesSnapshotForPolicy().anyAppControlEnabled
    }

    private func preferencesSnapshotForPolicy() -> HostPreferences {
        // Actor isolation makes this a race-free read of the same state that is
        // durably updated before the UI revokes grants.
        snapshot()
    }
}
