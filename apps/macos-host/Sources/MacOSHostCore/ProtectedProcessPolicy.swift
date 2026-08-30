import Foundation

public struct PolicyDecision: Equatable, Sendable {
    public let allowed: Bool
    public let reasonCode: String?

    public static let allow = PolicyDecision(allowed: true, reasonCode: nil)

    public static func deny(_ reasonCode: String) -> PolicyDecision {
        PolicyDecision(allowed: false, reasonCode: reasonCode)
    }
}

public struct ProtectedProcessPolicy: Sendable {
    public let ownBundleIdentifier: String
    public let blockedBundleIdentifiers: Set<String>
    public let blockedProcessNames: Set<String>

    public init(
        ownBundleIdentifier: String = "com.jmeguilos.computer-use-mcp.host",
        blockedBundleIdentifiers: Set<String> = ProtectedProcessPolicy.defaultBlockedBundleIdentifiers,
        blockedProcessNames: Set<String> = ProtectedProcessPolicy.defaultBlockedProcessNames
    ) {
        self.ownBundleIdentifier = ownBundleIdentifier
        self.blockedBundleIdentifiers = blockedBundleIdentifiers
        self.blockedProcessNames = blockedProcessNames
    }

    public func evaluate(_ window: WindowDescriptor) -> PolicyDecision {
        let identity = window.identity
        let surface = evaluateSurface(
            bundleIdentifier: identity.bundleIdentifier,
            processName: identity.ownerName,
            processID: identity.processID,
            title: window.title
        )
        guard surface.allowed else { return surface }
        if window.layer < 0 || window.layer > 100 {
            return .deny("nonstandard_window_layer")
        }
        return .allow
    }

    public func evaluate(bundleIdentifier: String, processName: String, processID: Int32) -> PolicyDecision {
        if bundleIdentifier == ownBundleIdentifier { return .deny("self_control_blocked") }
        let normalizedBundle = bundleIdentifier.lowercased()
        let normalizedName = processName.lowercased()
        if blockedBundleIdentifiers.contains(bundleIdentifier) ||
            Self.blockedBundleIdentifierFragments.contains(where: normalizedBundle.contains) {
            return .deny("protected_bundle")
        }
        if blockedProcessNames.contains(normalizedName) ||
            Self.blockedProcessNameFragments.contains(where: normalizedName.contains) {
            return .deny("protected_process")
        }
        if processID <= 1 { return .deny("invalid_process") }
        return .allow
    }

    public func evaluateSurface(
        bundleIdentifier: String,
        processName: String,
        processID: Int32,
        title: String?
    ) -> PolicyDecision {
        let process = evaluate(
            bundleIdentifier: bundleIdentifier,
            processName: processName,
            processID: processID
        )
        guard process.allowed else { return process }
        guard let title = title?.lowercased() else { return .allow }
        if Self.protectedAuthorizationTitleFragments.contains(where: title.contains) {
            return .deny("protected_authorization_surface")
        }
        if bundleIdentifier == "com.apple.systempreferences",
           Self.protectedSystemSettingsTitleFragments.contains(where: title.contains) {
            return .deny("protected_system_settings_surface")
        }
        return .allow
    }

    /// ScreenCaptureKit excludes display pixels at application granularity.
    /// System Settings is conservatively excluded as a whole from display
    /// capture and is also unavailable as an explicit alpha window target.
    public func excludesApplicationFromDisplayCapture(
        bundleIdentifier: String,
        processName: String,
        processID: Int32
    ) -> Bool {
        bundleIdentifier == "com.apple.systempreferences" ||
            !evaluate(
                bundleIdentifier: bundleIdentifier,
                processName: processName,
                processID: processID
            ).allowed
    }

    public static let defaultBlockedBundleIdentifiers: Set<String> = [
        "com.apple.SecurityAgent",
        "com.apple.CoreServicesUIAgent",
        "com.apple.loginwindow",
        "com.apple.installer",
        "com.apple.TCC",
        "com.apple.systempreferences",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty",
        "co.zeit.hyper",
        "org.tabby",
        "com.eugeny.tabby",
        "com.raphaelamorim.rio",
        "dev.waveterm",
        "org.xquartz.xterm",
    ]

    public static let defaultBlockedProcessNames: Set<String> = [
        "authorizationhost",
        "authd",
        "coreservicesuiagent",
        "loginwindow",
        "securityagent",
        "tccd",
        "terminal",
        "iterm2",
        "warp",
        "wezterm-gui",
        "alacritty",
        "kitty",
        "ghostty",
        "hyper",
        "tabby",
        "rio",
        "waveterm",
        "xterm",
    ]

    /// Alpha policy intentionally favors false positives over sending input to
    /// a newly branded or variant terminal bundle. These fragments complement
    /// the exact known-ID list and are evaluated case-insensitively.
    public static let blockedBundleIdentifierFragments = [
        "terminal", "iterm", "warp", "wezterm", "alacritty", "kitty",
        "ghostty", "hyper", "tabby", "waveterm", "xterm",
    ]

    public static let blockedProcessNameFragments = [
        "terminal", "iterm", "warp", "wezterm", "alacritty", "kitty",
        "ghostty", "hyper", "tabby", "waveterm", "xterm",
    ]

    public static let protectedSystemSettingsTitleFragments = [
        "privacy & security", "privacy and security", "login password", "touch id",
        "users & groups", "users and groups", "profiles", "lockdown mode",
        "filevault", "screen recording", "accessibility permission",
    ]

    public static let protectedAuthorizationTitleFragments = [
        "authentication required", "authorization required", "administrator password",
        "enter your password to allow", "enter password to allow", "password is required",
        "unlock to make changes", "security code", "verification code",
    ]
}
