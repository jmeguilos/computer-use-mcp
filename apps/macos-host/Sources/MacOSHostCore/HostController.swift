import AppKit
import CryptoKit
import Foundation

public enum PublicCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case observe
    case interact
    case clipboardWrite = "clipboard_write"
}

public enum PublicCapabilityPolicy {
    public static func isCoherent(_ capabilities: Set<PublicCapability>) -> Bool {
        (!capabilities.contains(.interact) || capabilities.contains(.observe)) &&
            (!capabilities.contains(.clipboardWrite) ||
                (capabilities.contains(.observe) && capabilities.contains(.interact)))
    }

    public static func requiresExclusiveTargetLock(_ capabilities: Set<PublicCapability>) -> Bool {
        capabilities.contains(.interact)
    }
}

public struct GrantChoice: Sendable {
    public let scope: GrantScope
    public let frame: Rect
    public let title: String
    public let targetMetadata: JSONValue
    public let targetKey: String
    public let displayFrame: Rect
}

public struct AccessApprovalRequest: Sendable {
    public let connectionID: UUID
    public let requesterName: String
    public let applicationName: String?
    public let bundleIdentifier: String?
    public let reason: String
    public let candidates: [GrantChoice]
    public let capabilities: Set<PublicCapability>
    public let displayTarget: Bool
    public let appConsentExists: Bool

    public init(
        connectionID: UUID,
        requesterName: String = "MCP client",
        applicationName: String? = nil,
        bundleIdentifier: String? = nil,
        reason: String,
        candidates: [GrantChoice],
        capabilities: Set<PublicCapability>,
        displayTarget: Bool,
        appConsentExists: Bool
    ) {
        self.connectionID = connectionID
        self.requesterName = requesterName
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.reason = reason
        self.candidates = candidates
        self.capabilities = capabilities
        self.displayTarget = displayTarget
        self.appConsentExists = appConsentExists
    }
}

public struct AccessApprovalDecision: Sendable {
    public let selected: GrantChoice?
    public let persistence: GrantPersistence

    public init(selected: GrantChoice?, persistence: GrantPersistence) {
        self.selected = selected
        self.persistence = persistence
    }

    public static let denied = AccessApprovalDecision(selected: nil, persistence: .allowOnce)
}

public struct LaunchApprovalRequest: Sendable {
    public let connectionID: UUID
    public let requesterName: String
    public let appName: String
    public let bundleIdentifier: String
    public let reason: String
    public let capabilities: Set<PublicCapability>

    public init(
        connectionID: UUID,
        requesterName: String = "MCP client",
        appName: String,
        bundleIdentifier: String,
        reason: String,
        capabilities: Set<PublicCapability>
    ) {
        self.connectionID = connectionID
        self.requesterName = requesterName
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.reason = reason
        self.capabilities = capabilities
    }
}

public protocol AccessApprovalPresenting: Sendable {
    /// Separate consent boundary for a state-changing launch. This happens
    /// before NSWorkspace is asked to start an absent application. Launch never
    /// grants control; later resolution still requires either native exact-
    /// window selection or a matching unique-window Always Allow policy.
    func requestLaunchApproval(
        _ request: LaunchApprovalRequest,
        cancellation: any InteractionCancellationChecking
    ) async -> Bool
    func requestApproval(
        _ request: AccessApprovalRequest,
        cancellation: any InteractionCancellationChecking
    ) async -> AccessApprovalDecision
}

public extension AccessApprovalPresenting {
    func requestLaunchApproval(
        _ request: LaunchApprovalRequest,
        cancellation: any InteractionCancellationChecking
    ) async -> Bool { false }
}

public struct DenyingAccessApprovalPresenter: AccessApprovalPresenting {
    public init() {}
    public func requestLaunchApproval(
        _ request: LaunchApprovalRequest,
        cancellation: any InteractionCancellationChecking
    ) async -> Bool { false }
    public func requestApproval(
        _ request: AccessApprovalRequest,
        cancellation: any InteractionCancellationChecking
    ) async -> AccessApprovalDecision { .denied }
}

public struct ApplicationLaunchCandidate: Equatable, Sendable {
    public let url: URL
    public let bundleIdentifier: String
    public let name: String
}

public protocol ApplicationLaunching: Sendable {
    func candidate(for selector: ApplicationSelector) -> ApplicationLaunchCandidate?
    func launch(_ candidate: ApplicationLaunchCandidate) async throws
}

public struct WorkspaceApplicationLauncher: ApplicationLaunching {
    public init() {}

    public func candidate(for selector: ApplicationSelector) -> ApplicationLaunchCandidate? {
        let url: URL?
        switch selector.kind {
        case .bundleID:
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: selector.value)
        case .path:
            url = URL(fileURLWithPath: selector.value)
                .resolvingSymlinksInPath()
                .standardizedFileURL
        case .name:
            // Names are not a stable launch authority. Callers may still use a
            // name to select an already-running application.
            url = nil
        }
        guard let url, let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier, !identifier.isEmpty else { return nil }
        if selector.kind == .bundleID, identifier != selector.value { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return ApplicationLaunchCandidate(url: url, bundleIdentifier: identifier, name: name)
    }

    public func launch(_ candidate: ApplicationLaunchCandidate) async throws {
        _ = try await NSWorkspace.shared.openApplication(
            at: candidate.url,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}

public protocol RiskApprovalPresenting: Sendable {
    func requestApproval(
        _ challenge: RiskChallenge,
        summary: String,
        cancellation: any InteractionCancellationChecking
    ) async -> Bool
}

public struct DenyingRiskApprovalPresenter: RiskApprovalPresenting {
    public init() {}
    public func requestApproval(
        _ challenge: RiskChallenge,
        summary: String,
        cancellation: any InteractionCancellationChecking
    ) async -> Bool { false }
}

public enum RiskApprovalSummaryBuilder {
    public static func summary(
        request: HostActionRequest,
        target: JSONValue,
        harnessName: String,
        element: AccessibilityActionDescriptor? = nil
    ) -> String {
        let object = target.objectValue ?? [:]
        let app = object["app"]?.objectValue
        let appName = escaped(app?["name"]?.stringValue ?? app?["bundleId"]?.stringValue ?? "Display", maximum: 256)
        let windowTitle = object["title"]?.stringValue.map { escaped($0, maximum: 512) }
        var lines = [
            "Harness: \(escaped(harnessName, maximum: 128))",
            "Target: \(windowTitle.map { "\(appName) — \($0)" } ?? appName)",
            "Action: \(request.kind.rawValue)",
        ]
        switch request.selector {
        case .point(let point):
            lines.append("Selector: point (\(String(format: "%.1f", point.x)), \(String(format: "%.1f", point.y)))")
        case .element:
            if let element {
                let label = element.semanticLabel.map { ", label \(escaped($0, maximum: 512))" } ?? ""
                lines.append("Selector: \(escaped(element.role, maximum: 128))\(label)\(element.secure ? ", secure" : "")")
                if !element.semanticContext.isEmpty {
                    let context = element.semanticContext.prefix(3)
                        .map { escaped($0, maximum: 512) }
                        .joined(separator: " > ")
                    lines.append("AX context: \(context)")
                }
            } else { lines.append("Selector: accessibility element") }
        case nil: break
        }
        if let key = request.key {
            let modifiers = (request.modifiers ?? []).joined(separator: "+")
            lines.append("Key: \(modifiers.isEmpty ? "" : modifiers + "+")\(escaped(key, maximum: 64))")
        }
        if let text = request.text {
            lines.append(payloadSummary(
                label: "Text",
                value: text,
                format: request.format ?? "text",
                element: element
            ))
        }
        if let value = request.value {
            lines.append(payloadSummary(label: "Value", value: value, format: nil, element: element))
        }
        if let action = request.action { lines.append("Semantic action: \(escaped(action, maximum: 256))") }
        lines.append("Claimed intent: \(escaped(request.intent, maximum: 300))")
        return NativeUISanitizer.boundedLiteral(lines.joined(separator: "\n"), maximumUTF16: 2_000)
    }

    private static func escaped(_ value: String, maximum: Int) -> String {
        NativeUISanitizer.escaped(
            value,
            maximumInputUTF16: maximum,
            maximumOutputUTF16: min(1_500, maximum * 6)
        )
    }

    private static func payloadSummary(
        label: String,
        value: String,
        format: String?,
        element: AccessibilityActionDescriptor?
    ) -> String {
        let formatMetadata = format.map { "; format \(escaped($0, maximum: 32))" } ?? ""
        let metadata = "\(value.utf16.count) UTF-16 code units" + formatMetadata
        guard element?.secure == false else {
            return "\(label) payload: sensitive; \(metadata); preview hidden"
        }
        return "\(label) payload: \(metadata); preview \(escapedPreview(value))"
    }

    private static func escapedPreview(_ value: String, maximumUTF16: Int = 64) -> String {
        let preview = NativeUISanitizer.escaped(
            value,
            maximumInputUTF16: maximumUTF16,
            maximumOutputUTF16: 256
        )
        return "\"\(preview)\""
    }
}

public struct IndicatorState: Sendable {
    public let connectionID: UUID
    public let grantID: UUID
    public let targetFrame: Rect
    public let targetTitle: String
    public let controlling: Bool
    public let targetWindowID: UInt32?
    public let targetIdentity: WindowIdentity?
    public let targetDisplayIdentity: DisplayIdentity?
    public let displayTopLeftFrame: Rect
    public let harnessName: String
    public let mode: String
}

public protocol ControlIndicatorPresenting: Sendable {
    func show(_ state: IndicatorState) async throws
    func hide(grantID: UUID) async
    func hide(connectionID: UUID) async
    func hideAll() async
}

public struct NullControlIndicator: ControlIndicatorPresenting {
    public init() {}
    public func show(_ state: IndicatorState) async throws {}
    public func hide(grantID: UUID) async {}
    public func hide(connectionID: UUID) async {}
    public func hideAll() async {}
}

public struct RequestAccessParameters: Codable, Sendable {
    public let target: AccessTargetRequest
    public let reason: String
    public let capabilities: Set<PublicCapability>
    public let timeoutMs: Int
}

public struct GrantIDParameters: Codable, Sendable {
    public let grantID: UUID
    private enum CodingKeys: String, CodingKey { case grantID = "grantId" }
}

public struct GetStateParameters: Codable, Sendable {
    public let grantID: UUID
    public let sinceFrameID: UUID?
    public let screenshot: String
    public let maxWidthPx: Int
    public let includeAccessibility: Bool
    public let maxAccessibilityChars: Int
    public let timeoutMs: Int
    private enum CodingKeys: String, CodingKey {
        case grantID = "grantId"
        case sinceFrameID = "sinceFrameId"
        case screenshot, maxWidthPx, includeAccessibility, maxAccessibilityChars, timeoutMs
    }
}

public enum ApprovalMode: String, Codable, Equatable, Sendable { case elicitation; case native }

public enum HostActionKind: String, Codable, Sendable {
    case click
    case drag
    case scroll
    case pressKey
    case typeText
    case paste
    case setValue
    case selectText
    case performSecondaryAction
}

public enum ActionSelector: Codable, Sendable {
    case element(String)
    case point(Point)

    private enum CodingKeys: String, CodingKey { case kind, elementID = "elementId", x, y }
    private enum Kind: String, Codable { case element; case point }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .element: self = .element(try container.decode(String.self, forKey: .elementID))
        case .point:
            self = .point(Point(
                x: try container.decode(Double.self, forKey: .x),
                y: try container.decode(Double.self, forKey: .y)
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .element(let id):
            try container.encode(Kind.element, forKey: .kind)
            try container.encode(id, forKey: .elementID)
        case .point(let point):
            try container.encode(Kind.point, forKey: .kind)
            try container.encode(point.x, forKey: .x)
            try container.encode(point.y, forKey: .y)
        }
    }
}

public struct HostActionRequest: Codable, Sendable {
    public let kind: HostActionKind
    public let grantID: UUID
    public let frameID: UUID
    public let intent: String
    public let approvalRequestID: UUID?
    public let timeoutMs: Int
    public let approvalMode: ApprovalMode
    public let selector: ActionSelector?
    public let from: ActionSelector?
    public let to: ActionSelector?
    public let mouseButton: String?
    public let clickCount: Int?
    public let durationMs: Int?
    public let direction: String?
    public let amount: Double?
    public let unit: String?
    public let key: String?
    public let modifiers: [String]?
    public let text: String?
    public let intervalMs: Int?
    public let format: String?
    public let value: String?
    public let prefix: String?
    public let suffix: String?
    public let selectionType: String?
    public let action: String?

    private enum CodingKeys: String, CodingKey {
        case kind
        case grantID = "grantId"
        case frameID = "frameId"
        case intent
        case approvalRequestID = "approvalRequestId"
        case timeoutMs, approvalMode, selector, from, to, mouseButton, clickCount, durationMs
        case direction, amount, unit, key, modifiers, text, intervalMs, format, value
        case prefix, suffix, selectionType, action
    }
}

public enum HostActionValidation {
    public static func validate(_ request: HostActionRequest) throws {
        guard (100...30_000).contains(request.timeoutMs),
              !request.intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.intent.utf16.count <= 300 else { throw invalid("Invalid action context") }

        switch request.kind {
        case .click:
            guard let selector = request.selector else { throw invalid("Click selector is required") }
            try validate(selector)
            guard request.mouseButton == nil || ["left", "right", "middle"].contains(request.mouseButton!),
                  request.clickCount == nil || (1...3).contains(request.clickCount!) else {
                throw invalid("Invalid click options")
            }
        case .drag:
            guard case .point? = request.from, case .point? = request.to else {
                throw invalid("Drag requires point selectors")
            }
            try validate(request.from!)
            try validate(request.to!)
            guard request.durationMs == nil || (0...5_000).contains(request.durationMs!) else {
                throw invalid("Invalid drag duration")
            }
        case .scroll:
            if let selector = request.selector { try validate(selector) }
            guard let direction = request.direction,
                  ["up", "down", "left", "right"].contains(direction),
                  (request.amount ?? 1).isFinite,
                  (0...100).contains(request.amount ?? 1),
                  (request.amount ?? 1) > 0,
                  ["lines", "pages"].contains(request.unit ?? "pages") else {
                throw invalid("Invalid scroll options")
            }
        case .pressKey:
            guard let key = request.key, PublicKeyMap.code(for: key) != nil else {
                throw invalid("Invalid key")
            }
            let allowed = Set(["command", "control", "option", "shift", "function"])
            let modifiers = request.modifiers ?? []
            guard modifiers.count <= 5, Set(modifiers).count == modifiers.count,
                  modifiers.allSatisfy(allowed.contains) else { throw invalid("Invalid modifiers") }
        case .typeText:
            guard let text = request.text, text.utf16.count <= 100_000,
                  request.intervalMs == nil || (0...1_000).contains(request.intervalMs!) else {
                throw invalid("Invalid typing options")
            }
        case .paste:
            guard let text = request.text, text.utf16.count <= 1_000_000,
                  request.format == nil || request.format == "text" else {
                throw invalid("Invalid paste options")
            }
        case .setValue:
            guard case .element? = request.selector,
                  let value = request.value, value.utf16.count <= 1_000_000 else {
                throw invalid("Invalid set-value options")
            }
            try validate(request.selector!)
        case .selectText:
            guard case .element? = request.selector,
                  let text = request.text, text.utf16.count <= 100_000,
                  (request.prefix?.utf16.count ?? 0) <= 1_000,
                  (request.suffix?.utf16.count ?? 0) <= 1_000,
                  request.selectionType == nil || ["text", "cursor_before", "cursor_after"].contains(request.selectionType!) else {
                throw invalid("Invalid text selection options")
            }
            try validate(request.selector!)
        case .performSecondaryAction:
            guard case .element? = request.selector,
                  let action = request.action,
                  !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  action.utf16.count <= 256 else { throw invalid("Invalid accessibility action") }
            try validate(request.selector!)
        }
    }

    private static func validate(_ selector: ActionSelector) throws {
        switch selector {
        case .element(let value):
            guard (8...256).contains(value.utf16.count) else { throw invalid("Invalid element identifier") }
        case .point(let point):
            guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0 else {
                throw invalid("Invalid point selector")
            }
        }
    }

    private static func invalid(_ message: String) -> WireError {
        WireError(code: "invalid_action", message: message)
    }
}

public enum ElementClickFallbackPolicy {
    /// AXPress can represent only a single primary-button activation. Other
    /// public click shapes must use the guarded coordinate path.
    public static func canUseAXPress(mouseButton: String, clickCount: Int) -> Bool {
        mouseButton == "left" && clickCount == 1
    }

    /// A generic AX failure can have an uncertain outcome, so it must never be
    /// followed by a coordinate click. A missing/unsupported action is the one
    /// fail-closed condition that proves AX did not dispatch the activation.
    public static func permitsFallback(after error: AccessibilityError) -> Bool {
        error == .actionUnsupported
    }

    /// Frame authority and risk classification were bound to this descriptor before
    /// execution. Reordering an action list is harmless; all semantic fields
    /// and the frame must otherwise remain exactly the same.
    public static func isSameBoundTarget(
        _ current: AccessibilityActionDescriptor,
        as approved: AccessibilityActionDescriptor
    ) -> Bool {
        current.hasSameControlSemantics(as: approved) && current.frame == approved.frame
    }

    public static func center(
        of descriptor: AccessibilityActionDescriptor,
        within frameBounds: Rect
    ) -> Point? {
        guard !descriptor.secure, let elementFrame = descriptor.frame,
              elementFrame.origin.x.isFinite, elementFrame.origin.y.isFinite,
              elementFrame.size.width.isFinite, elementFrame.size.height.isFinite,
              elementFrame.size.width > 0, elementFrame.size.height > 0,
              frameBounds.origin.x.isFinite, frameBounds.origin.y.isFinite,
              frameBounds.size.width.isFinite, frameBounds.size.height.isFinite,
              frameBounds.size.width > 0, frameBounds.size.height > 0 else { return nil }
        let point = Point(
            x: elementFrame.origin.x + elementFrame.size.width / 2,
            y: elementFrame.origin.y + elementFrame.size.height / 2
        )
        return frameBounds.cgRect.contains(point.cgPoint) ? point : nil
    }
}

public struct ApproveRiskParameters: Codable, Sendable {
    public let approvalRequestID: UUID
    public let approved: Bool
    private enum CodingKeys: String, CodingKey {
        case approvalRequestID = "approvalRequestId"
        case approved
    }
}

public struct HostRequestContext: Sendable {
    public let requestID: String
    public let connection: ConnectionRecord
    public let deadline: Date
}

public protocol HostMethodHandling: Sendable {
    func handle(method: String, params: JSONValue?, context: HostRequestContext) async throws -> JSONValue
    func disconnect(connectionID: UUID) async
    func emergencyStop() async
    func maintenance(now: Date) async
}

private struct GrantedMetadata: Sendable {
    let publicCapabilities: Set<PublicCapability>
    var target: JSONValue
    let targetKind: String
    let targetKey: String
    let auditTarget: AuditTarget
}

public actor HostController: HostMethodHandling {
    private let capture: ScreenCaptureServing
    private let accessibility: any AccessibilityServing
    private let accessibilitySnapshots: AccessibilityFrameSnapshotStore
    private let input: SyntheticInputDriving
    private let textController: TextInteractionController
    private let focus: FocusLeaseCoordinator
    private let grants: GrantStore
    private let frames: FrameResourceStore
    private let locks: ControllerLockStore
    private let actionGate: ActionExecutionGate
    private let risks: RiskApprovalStore
    private let actionApprovalPolicy: ActionApprovalPolicy
    private let permissions: SystemPermissionChecking
    private let controlPolicy: HostControlPolicyChecking
    private let protectedPolicy: ProtectedProcessPolicy
    private let syntheticDestinationGuard: any SyntheticDestinationGuarding
    private let accessPresenter: AccessApprovalPresenting
    private let applicationLauncher: ApplicationLaunching
    private let riskPresenter: RiskApprovalPresenting
    private let indicator: ControlIndicatorPresenting
    private let stopToken: InteractionStopToken
    private let auditStore: FileAuditStore?
    private let auditRedactor: AuditRedactor
    private let consentStore: PersistentAppConsentStore?
    private var grantMetadata: [UUID: GrantedMetadata] = [:]
    private var publishedGrantIDs: Set<UUID> = []
    private var lastAccessibilityRevision: [UUID: UInt64] = [:]
    private var maintenanceIdentityMissCounts: [UUID: Int] = [:]
    private var revokingConnections: Set<UUID> = []

    public init(
        capture: ScreenCaptureServing = ScreenCaptureService(),
        accessibility: any AccessibilityServing = AccessibilityController(),
        accessibilitySnapshots: AccessibilityFrameSnapshotStore = AccessibilityFrameSnapshotStore(),
        input: SyntheticInputDriving? = nil,
        focus: FocusLeaseCoordinator = FocusLeaseCoordinator(),
        grants: GrantStore = GrantStore(),
        frames: FrameResourceStore = FrameResourceStore(),
        locks: ControllerLockStore = ControllerLockStore(),
        actionGate: ActionExecutionGate = ActionExecutionGate(),
        risks: RiskApprovalStore = RiskApprovalStore(),
        actionApprovalPolicy: ActionApprovalPolicy = .grantScoped,
        permissions: SystemPermissionChecking = MacSystemPermissionChecker(),
        controlPolicy: HostControlPolicyChecking = AlwaysEnabledHostControlPolicy(),
        protectedPolicy: ProtectedProcessPolicy = ProtectedProcessPolicy(),
        syntheticDestinationGuard: (any SyntheticDestinationGuarding)? = nil,
        accessPresenter: AccessApprovalPresenting = DenyingAccessApprovalPresenter(),
        applicationLauncher: ApplicationLaunching = WorkspaceApplicationLauncher(),
        riskPresenter: RiskApprovalPresenting = DenyingRiskApprovalPresenter(),
        indicator: ControlIndicatorPresenting = NullControlIndicator(),
        stopToken: InteractionStopToken = InteractionStopToken(),
        auditStore: FileAuditStore? = nil,
        consentStore: PersistentAppConsentStore? = nil,
        auditSalt: Data = Data("ComputerUseMCP-audit-v1".utf8)
    ) {
        let resolvedInput = input ?? CGEventInputDriver(permissionChecker: permissions)
        self.capture = capture
        self.accessibility = accessibility
        self.accessibilitySnapshots = accessibilitySnapshots
        self.input = resolvedInput
        self.textController = TextInteractionController(input: resolvedInput)
        self.focus = focus
        self.grants = grants
        self.frames = frames
        self.locks = locks
        self.actionGate = actionGate
        self.risks = risks
        self.actionApprovalPolicy = actionApprovalPolicy
        self.permissions = permissions
        self.controlPolicy = controlPolicy
        self.protectedPolicy = protectedPolicy
        self.syntheticDestinationGuard = syntheticDestinationGuard ?? SyntheticDestinationGuard(protectedPolicy: protectedPolicy)
        self.accessPresenter = accessPresenter
        self.applicationLauncher = applicationLauncher
        self.riskPresenter = riskPresenter
        self.indicator = indicator
        self.stopToken = stopToken
        self.auditStore = auditStore
        self.consentStore = consentStore
        self.auditRedactor = AuditRedactor(salt: auditSalt)
    }

    public func handle(method: String, params: JSONValue?, context: HostRequestContext) async throws -> JSONValue {
        try check(context)
        if !["status", "releaseAccess", "stop"].contains(method) {
            try await requireAppControlEnabled()
        }
        switch method {
        case "status": return try await status(context)
        case "listDisplays": return try await listDisplays(required(params))
        case "listApps": return try await listApps(required(params), context)
        case "requestAccess": return try await requestAccess(required(params), context)
        case "releaseAccess": return try await releaseAccess(required(params), context)
        case "getState": return try await getState(required(params), context)
        case "action": return try await action(required(params), context)
        case "approveRisk": return try await approveRisk(required(params), context)
        case "stop": await emergencyStop(); return .object(["status": .string("stopped")])
        default: throw WireError(code: "method_not_found", message: "Unsupported native method")
        }
    }

    public func disconnect(connectionID: UUID) async {
        revokingConnections.insert(connectionID)
        stopToken.stop(connectionID: connectionID)
        let revoked = await grants.revoke(connectionID: connectionID)
        await frames.revoke(connectionID: connectionID)
        for id in revoked {
            await accessibility.close(sessionID: id)
            await accessibilitySnapshots.revoke(grantID: id)
            grantMetadata.removeValue(forKey: id)
            publishedGrantIDs.remove(id)
            lastAccessibilityRevision.removeValue(forKey: id)
            maintenanceIdentityMissCounts.removeValue(forKey: id)
        }
        await risks.revoke(connectionID: connectionID)
        await locks.revoke(connectionID: connectionID)
        await indicator.hide(connectionID: connectionID)
        revokingConnections.remove(connectionID)
    }

    public func emergencyStop() async {
        stopToken.stopAll()
        let revoked = await grants.revokeAll()
        await frames.revokeAll()
        for id in revoked { await accessibility.close(sessionID: id) }
        await accessibilitySnapshots.revokeAll()
        await risks.revokeAll()
        grantMetadata.removeAll()
        publishedGrantIDs.removeAll()
        lastAccessibilityRevision.removeAll()
        maintenanceIdentityMissCounts.removeAll()
        await locks.revokeAll()
        await indicator.hideAll()
    }

    public func activeGrantCount(now: Date = Date()) async -> Int {
        await maintenance(now: now)
        return publishedGrantIDs.count
    }

    /// Trusted local UI path for the Stop button on one grant's rail.
    public func stop(grantID: UUID) async {
        stopToken.stop(grantID: grantID)
        guard let grant = await grants.revoke(grantID: grantID) else {
            maintenanceIdentityMissCounts.removeValue(forKey: grantID)
            await indicator.hide(grantID: grantID)
            return
        }
        await frames.revoke(grantIDs: [grantID])
        await accessibility.close(sessionID: grantID)
        await accessibilitySnapshots.revoke(grantID: grantID)
        await locks.release(grantID: grantID)
        await risks.revoke(connectionID: grant.connectionID)
        grantMetadata.removeValue(forKey: grantID)
        publishedGrantIDs.remove(grantID)
        lastAccessibilityRevision.removeValue(forKey: grantID)
        maintenanceIdentityMissCounts.removeValue(forKey: grantID)
        await indicator.hide(grantID: grantID)
    }

    public func maintenance(now: Date = Date()) async {
        let expired = await grants.revokeExpired(now: now)
        for grant in expired {
            stopToken.stop(grantID: grant.id)
            await frames.revoke(grantIDs: [grant.id])
            await accessibility.close(sessionID: grant.id)
            await accessibilitySnapshots.revoke(grantID: grant.id)
            await locks.release(grantID: grant.id)
            await risks.revoke(connectionID: grant.connectionID)
            await indicator.hide(grantID: grant.id)
            grantMetadata.removeValue(forKey: grant.id)
            publishedGrantIDs.remove(grant.id)
            lastAccessibilityRevision.removeValue(forKey: grant.id)
            maintenanceIdentityMissCounts.removeValue(forKey: grant.id)
        }

        let activeGrants = await grants.active(now: now).filter {
            publishedGrantIDs.contains($0.id)
        }
        guard !activeGrants.isEmpty else { return }

        // SCShareableContent is requested with `onScreenWindowsOnly: false`, so
        // minimized, hidden, and other-Space windows remain present here. A
        // successful inventory can therefore revoke an exact target when its
        // immutable window identity disappears/is reused, or its approved
        // display configuration changes. A transient inventory failure is not
        // evidence that either target went away.
        guard let inventory = try? await capture.inventory() else { return }
        let currentByWindowID = Dictionary(
            grouping: inventory.applications.flatMap(\.windows),
            by: { $0.identity.windowID }
        )
        for grant in activeGrants {
            let isCurrent: Bool
            let mayBeTransient: Bool
            switch grant.scope {
            case .window(let expected):
                let candidates = currentByWindowID[expected.windowID] ?? []
                if let current = candidates.first(where: { $0.identity == expected }),
                   protectedPolicy.evaluate(current).allowed {
                    do {
                        try await accessibility.validateWindowBinding(
                            sessionID: grant.id,
                            window: current
                        )
                        isCurrent = true
                        mayBeTransient = false
                    } catch let error as AccessibilityError {
                        isCurrent = false
                        // AX may briefly omit or ambiguously report the same
                        // WindowServer target during a focus/Space transition.
                        // A concrete binding change or permission/session
                        // failure is positive revocation evidence.
                        mayBeTransient = error == .windowNotFound || error == .windowMappingAmbiguous
                    } catch {
                        isCurrent = false
                        mayBeTransient = false
                    }
                } else {
                    isCurrent = false
                    // SCShareableContent includes hidden, minimized, and
                    // other-Space windows. Absence, a reused numeric ID, or a
                    // newly protected target is therefore positive revocation
                    // evidence. Only transient AX mapping of an otherwise
                    // present exact WindowServer target receives a grace bound.
                    mayBeTransient = false
                }
            case .display(let expected):
                // A display grant is bound to the approved geometry, scale,
                // mirroring state, and main-display state. Reconfiguration is
                // a new target boundary even when CoreGraphics reuses the ID.
                isCurrent = inventory.displays.contains(expected)
                mayBeTransient = false
            }
            if isCurrent {
                maintenanceIdentityMissCounts.removeValue(forKey: grant.id)
                continue
            }
            guard mayBeTransient else {
                await stop(grantID: grant.id)
                continue
            }
            // WindowServer and Accessibility can each produce one transient
            // miss during focus, Space, or visibility transitions. Action-time
            // validation remains immediate and fail-closed; maintenance waits
            // for three consecutive corroborating misses before revoking the
            // visible grant.
            let missCount = min(3, maintenanceIdentityMissCounts[grant.id, default: 0] + 1)
            maintenanceIdentityMissCounts[grant.id] = missCount
            guard missCount >= 3 else { continue }
            await stop(grantID: grant.id)
        }
    }

    private func status(_ context: HostRequestContext) async throws -> JSONValue {
        await maintenance(now: Date())
        let snapshot = permissions.snapshot()
        let appControlEnabled = await controlPolicy.isAppControlEnabled()
        let active = await grants.active(connectionID: context.connection.id)
            .filter { publishedGrantIDs.contains($0.id) }
        let summaries: [JSONValue] = active.map { grant in
            return .object([
                "grantId": .string(grant.id.uuidString),
                "targetKind": .string(grantMetadata[grant.id]?.targetKind ?? "window"),
                "idleExpiresAt": .string(Self.iso(grant.expiresAt)),
            ])
        }
        return .object([
            "status": .string(
                !appControlEnabled
                    ? "degraded"
                    : (snapshot.isReadyForInteractiveControl ? "ready" : "permission_required")
            ),
            "nativeVersion": .string("0.1.0-alpha.1"),
            "platform": .string("macos"),
            "appControlEnabled": .bool(appControlEnabled),
            "actionAuthorization": .string(actionApprovalPolicy.rawValue),
            "permissions": .object([
                "accessibility": .string(snapshot.accessibility.publicName),
                "screenRecording": .string(snapshot.screenCapture.publicName),
            ]),
            "activeGrants": .array(summaries),
        ])
    }

    private func listDisplays(_ params: JSONValue) async throws -> JSONValue {
        let includeMirrored = params.objectValue?["includeMirrored"]?.boolValue ?? true
        let displays = try await capture.inventory().displays
            .filter { includeMirrored || !$0.isMirrored }
            .map(displayJSON)
        return .object(["displays": .array(displays)])
    }

    private func listApps(_ params: JSONValue, _ context: HostRequestContext) async throws -> JSONValue {
        let apps: [JSONValue] = try await capture.inventory().applications.filter { application in
            application.processID > 1 &&
                !application.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !application.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.map { application in
            // Without a verified GUI ancestor, the bridge cannot prove which
            // application belongs to the requesting harness. Inventory stays
            // readable, but every candidate must remain non-grantable so
            // self-control cannot fail open.
            let canExcludeRequestingHarness = context.connection.peer.captureExclusion != nil
            let isRequestingHarness = context.connection.peer.matchesHarnessApplication(
                bundleIdentifier: application.bundleIdentifier
            )
            let hasGrantableWindow = application.windows.contains {
                protectedPolicy.evaluate($0).allowed
            }
            return .object([
                "bundleId": .string(application.bundleIdentifier),
                "name": .string(application.name),
                "isRunning": .bool(true),
                "pid": .number(Double(application.processID)),
                "windowCount": .number(Double(application.windows.count)),
                "grantable": .bool(
                    canExcludeRequestingHarness &&
                        !application.isProtected &&
                        !isRequestingHarness &&
                        hasGrantableWindow
                ),
            ])
        }
        return .object(["apps": .array(apps)])
    }

    private func requestAccess(_ value: JSONValue, _ context: HostRequestContext) async throws -> JSONValue {
        let request = try value.decode(RequestAccessParameters.self)
        guard (100...300_000).contains(request.timeoutMs) else {
            throw WireError(code: "ACTION_TIMEOUT", message: "Access timeout must be between 100ms and 300000ms")
        }
        let requestCancellation = RelayedInteractionCancellation(
            base: DeadlineInteractionCancellation(
                base: stopToken.scope(connectionID: context.connection.id),
                deadline: min(
                    context.deadline,
                    Date().addingTimeInterval(Double(request.timeoutMs) / 1_000)
                )
            )
        )
        guard !request.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.reason.utf16.count <= 500,
              !request.capabilities.isEmpty,
              request.capabilities.count <= 3 else {
            throw WireError(code: "invalid_request", message: "reason and capabilities are required")
        }
        guard PublicCapabilityPolicy.isCoherent(request.capabilities) else {
            throw WireError(
                code: "ACCESS_DENIED",
                message: "interact requires observe; clipboard_write requires observe and interact"
            )
        }
        // Window and display grants must exclude the requesting GUI itself.
        // If the signed bridge cannot derive and bind that ancestor, there is
        // no safe target set to present. Keep diagnostics available, but deny
        // all authority creation for this connection.
        guard context.connection.peer.captureExclusion != nil else {
            return .object([
                "status": .string("denied"),
                "message": .string(
                    "The requesting application identity could not be verified; restart the MCP client from its signed macOS application before requesting control"
                ),
            ])
        }
        let requestedDisplayTarget: Bool = {
            if case .display = request.target { return true }
            return false
        }()
        let preflightCapabilities = mapCapabilities(
            request.capabilities,
            display: requestedDisplayTarget
        )
        for capability in preflightCapabilities where !permissions.snapshot().permits(capability) {
            return .object([
                "status": .string("permission_required"),
                "message": .string("Required macOS permission is missing"),
            ])
        }
        let inventory = try await capture.inventory()
        var choices: [GrantChoice] = []
        var windowDescriptorsByTargetKey: [String: WindowDescriptor] = [:]
        var windowBindingsByTargetKey: [String: AccessibilityWindowBinding] = [:]
        var presentationApplicationName: String?
        var presentationBundleIdentifier: String?
        let isDisplay: Bool
        switch request.target {
        case .display(let displayID):
            isDisplay = true
            guard let numericID = Self.parseDisplayID(displayID),
                  let display = inventory.displays.first(where: { $0.displayID == numericID }) else {
                throw WireError(code: "display_not_found", message: "Display is unavailable")
            }
            choices = [GrantChoice(
                scope: .display(display),
                frame: display.frame,
                title: display.name,
                targetMetadata: .object(["kind": .string("display"), "display": displayJSON(display)]),
                targetKey: "display:\(display.displayID)",
                displayFrame: display.frame
            )]
        case .window(let selector, let hint, let launch):
            isDisplay = false
            guard !selector.value.isEmpty,
                  selector.value.utf16.count <= (selector.kind == .path ? 4_096 : 512),
                  selector.kind != .path || selector.value.hasPrefix("/"),
                  hint == nil || (!(hint!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && hint!.utf16.count <= 500) else {
                throw WireError(code: "invalid_request", message: "Invalid application or window selector")
            }
            var applications = matchingApps(selector, in: inventory.applications)
            if applications.isEmpty, launch {
                guard selector.kind != .path else {
                    throw WireError(
                        code: "ACCESS_DENIED",
                        message: "launch_if_needed is unavailable for path selectors; launch the app explicitly first"
                    )
                }
                guard let candidate = applicationLauncher.candidate(for: selector) else {
                    throw WireError(code: "APP_NOT_RUNNING", message: "The requested application cannot be safely resolved for launch")
                }
                guard !context.connection.peer.matchesHarnessApplication(
                    bundleIdentifier: candidate.bundleIdentifier
                ) else {
                    return .object([
                        "status": .string("denied"),
                        "message": .string("Controlling the requesting harness is blocked"),
                    ])
                }
                guard protectedPolicy.evaluate(
                    bundleIdentifier: candidate.bundleIdentifier,
                    processName: candidate.name,
                    processID: 2
                ).allowed else {
                    return .object(["status": .string("denied"), "message": .string("The application is protected")])
                }
                let launchApproved = await withTaskCancellationHandler {
                    await accessPresenter.requestLaunchApproval(
                        LaunchApprovalRequest(
                            connectionID: context.connection.id,
                            requesterName: context.connection.peer.name,
                            appName: candidate.name,
                            bundleIdentifier: candidate.bundleIdentifier,
                            reason: request.reason,
                            capabilities: request.capabilities
                        ),
                        cancellation: requestCancellation
                    )
                } onCancel: {
                    requestCancellation.cancel()
                }
                try check(context)
                try requestCancellation.check()
                guard launchApproved else {
                    return .object(["status": .string("denied"), "message": .string("User denied application launch")])
                }
                applications = try await launchAndFind(
                    selector,
                    candidate: candidate,
                    context: context,
                    cancellation: requestCancellation
                )
                try check(context)
                try requestCancellation.check()
            }
            guard applications.count == 1, !applications[0].isProtected else {
                return .object(["status": .string("denied"), "message": .string("Application is unavailable or protected")])
            }
            let app = applications[0]
            guard !context.connection.peer.matchesHarnessApplication(
                bundleIdentifier: app.bundleIdentifier
            ) else {
                return .object([
                    "status": .string("denied"),
                    "message": .string("Controlling the requesting harness is blocked"),
                ])
            }
            presentationApplicationName = app.name
            presentationBundleIdentifier = app.bundleIdentifier
            let candidates = app.windows.filter { window in
                guard let hint else { return true }
                return window.title?.localizedCaseInsensitiveContains(hint) == true
            }.filter {
                protectedPolicy.evaluate($0).allowed &&
                    !context.connection.peer.matchesHarnessWindow($0.identity)
            }
            guard !candidates.isEmpty else {
                return .object(["status": .string("denied"), "message": .string("No matching grantable window")])
            }
            for window in candidates {
                let displayID = bestDisplay(for: window.frame, displays: inventory.displays)?.displayID ?? 0
                let displayFrame = bestDisplay(for: window.frame, displays: inventory.displays)?.frame
                    ?? Rect(CGDisplayBounds(CGMainDisplayID()))
                let targetKey = "window:\(window.identity.windowID)"
                // Bind the concrete AX window before human selection. A
                // close/recreate cycle during a long-running picker cannot
                // inherit the candidate merely because macOS reused the same
                // numeric CGWindowID and metadata.
                guard let binding = try? await accessibility.createWindowBinding(window: window) else {
                    continue
                }
                choices.append(GrantChoice(
                    scope: .window(window.identity),
                    frame: window.frame,
                    title: window.title ?? app.name,
                    targetMetadata: windowTargetJSON(window, app: app, displayID: displayID),
                    targetKey: targetKey,
                    displayFrame: displayFrame
                ))
                windowDescriptorsByTargetKey[targetKey] = window
                windowBindingsByTargetKey[targetKey] = binding
            }
            guard !choices.isEmpty else {
                return .object([
                    "status": .string("denied"),
                    "message": .string("No matching window has an unambiguous Accessibility identity"),
                ])
            }
        }

        var appConsentExists = false
        if !isDisplay {
            for choice in choices {
                if case .window(let window) = choice.scope,
                   await consentStore?.allowsAutoGrantUniqueWindow(
                       requester: context.connection.peer,
                       window: window,
                       capabilities: request.capabilities
                   ) == true {
                    appConsentExists = true
                    break
                }
            }
        }
        // Always Allow App can satisfy only a later explicit request that has
        // already resolved to one safe, Accessibility-bound exact window. It
        // never grants ambient app authority, selects among multiple windows,
        // covers displays, or widens the capability ceiling.
        let decision: AccessApprovalDecision
        if appConsentExists, choices.count == 1, !isDisplay {
            decision = AccessApprovalDecision(
                selected: choices[0],
                persistence: .alwaysAllowApp
            )
        } else {
            decision = await withTaskCancellationHandler {
                await accessPresenter.requestApproval(
                    AccessApprovalRequest(
                        connectionID: context.connection.id,
                        requesterName: context.connection.peer.name,
                        applicationName: presentationApplicationName,
                        bundleIdentifier: presentationBundleIdentifier,
                        reason: request.reason,
                        candidates: choices,
                        capabilities: request.capabilities,
                        displayTarget: isDisplay,
                        appConsentExists: appConsentExists
                    ),
                    cancellation: requestCancellation
                )
            } onCancel: {
                requestCancellation.cancel()
            }
        }
        // Native UI is intentionally asynchronous. The caller may have timed
        // out, cancelled, or disconnected while the sheet was visible; never
        // create an orphan grant or indicator after that boundary.
        try check(context)
        try requestCancellation.check()
        try await requireAppControlEnabled()
        guard let choice = decision.selected,
              choices.contains(where: { $0.targetKey == choice.targetKey }) else {
            return .object(["status": .string("denied"), "message": .string("User denied target access")])
        }
        var selectedWindowDescriptor: WindowDescriptor?
        var selectedWindowBinding: AccessibilityWindowBinding?
        if case .window(let expectedIdentity) = choice.scope {
            guard let presentedWindow = windowDescriptorsByTargetKey[choice.targetKey],
                  let binding = windowBindingsByTargetKey[choice.targetKey] else {
                throw WireError(code: "INTERNAL_ERROR", message: "The selected window binding is unavailable")
            }
            let freshInventory = try await capture.inventory()
            guard let currentWindow = freshInventory.applications
                .flatMap(\.windows)
                .first(where: { $0.identity == expectedIdentity }),
                  currentWindow.frame == presentedWindow.frame,
                  currentWindow.title == presentedWindow.title,
                  currentWindow.layer == presentedWindow.layer,
                  protectedPolicy.evaluate(currentWindow).allowed else {
                return .object([
                    "status": .string("denied"),
                    "message": .string("The selected window changed while approval was open; request access again"),
                ])
            }
            do {
                try await accessibility.validateWindowBinding(binding, window: currentWindow)
            } catch {
                return .object([
                    "status": .string("denied"),
                    "message": .string("The selected window was recreated while approval was open; request access again"),
                ])
            }
            guard !context.connection.peer.matchesHarnessWindow(currentWindow.identity) else {
                return .object([
                    "status": .string("denied"),
                    "message": .string("Controlling the requesting harness is blocked"),
                ])
            }
            selectedWindowDescriptor = currentWindow
            selectedWindowBinding = binding
        }
        let persistence = isDisplay ? GrantPersistence.sessionOnly : decision.persistence
        let internalCapabilities = mapCapabilities(request.capabilities, display: isDisplay)
        for capability in internalCapabilities where !permissions.snapshot().permits(capability) {
            return .object(["status": .string("permission_required"), "message": .string("Required macOS permission is missing")])
        }
        let grantID = UUID()
        let controlsTarget = PublicCapabilityPolicy.requiresExclusiveTargetLock(request.capabilities)
        if controlsTarget {
            try await locks.acquire(targetKey: choice.targetKey, connectionID: context.connection.id, grantID: grantID)
        }
        let pendingGrantCancellation = stopToken.scope(
            connectionID: context.connection.id,
            grantID: grantID
        )
        let receipt: GrantReceipt
        do {
            if let selectedWindowDescriptor, let selectedWindowBinding {
                try await accessibility.openWindowSession(
                    sessionID: grantID,
                    binding: selectedWindowBinding,
                    window: selectedWindowDescriptor
                )
            }
            try await indicator.show(IndicatorState(
                connectionID: context.connection.id,
                grantID: grantID,
                targetFrame: choice.frame,
                targetTitle: choice.title,
                controlling: request.capabilities.contains(.interact),
                targetWindowID: {
                    if case .window(let window) = choice.scope { return window.windowID }
                    return nil
                }(),
                targetIdentity: {
                    if case .window(let window) = choice.scope { return window }
                    return nil
                }(),
                targetDisplayIdentity: {
                    if case .display(let display) = choice.scope { return display }
                    return nil
                }(),
                displayTopLeftFrame: choice.displayFrame,
                harnessName: context.connection.peer.name,
                mode: request.capabilities.contains(.interact) ? "Control" : "Observe"
            ))
            try check(context)
            try requestCancellation.check()
            try pendingGrantCancellation.check()
            try await requireAppControlEnabled()
            if persistence == .alwaysAllowApp,
               !appConsentExists,
               case .window(let window) = choice.scope {
                try await consentStore?.recordAutoGrantUniqueWindow(
                    requester: context.connection.peer,
                    window: window,
                    capabilities: request.capabilities
                )
                try check(context)
                try requestCancellation.check()
                try pendingGrantCancellation.check()
            }
            // Publish authority only after the mandatory rail is visible and
            // all consent work has completed. Until this point status/action
            // cannot discover or authorize the pending UUID.
            receipt = try await grants.issue(
                grantID: grantID,
                connectionID: context.connection.id,
                scope: choice.scope,
                capabilities: internalCapabilities,
                persistence: persistence
            )
            try check(context)
            try requestCancellation.check()
            try pendingGrantCancellation.check()
        } catch {
            stopToken.stop(grantID: grantID)
            _ = await grants.revoke(grantID: grantID)
            await accessibility.close(sessionID: grantID)
            await locks.release(grantID: grantID)
            await indicator.hide(grantID: grantID)
            if error is IndicatorPresentationError {
                throw WireError(code: "INTERNAL_ERROR", message: "The mandatory control indicator could not be presented")
            }
            throw error
        }
        grantMetadata[receipt.grantID] = GrantedMetadata(
            publicCapabilities: request.capabilities,
            target: choice.targetMetadata,
            targetKind: isDisplay ? "display" : "window",
            targetKey: choice.targetKey,
            auditTarget: Self.auditTarget(for: choice.scope, redactor: auditRedactor)
        )
        publishedGrantIDs.insert(receipt.grantID)
        return .object([
            "status": .string("granted"),
            "grantId": .string(receipt.grantID.uuidString),
            "target": choice.targetMetadata,
            "capabilities": .array(request.capabilities.sorted { $0.rawValue < $1.rawValue }.map { .string($0.rawValue) }),
            "idleExpiresAt": .string(Self.iso(receipt.expiresAt)),
            "sessionOnly": .bool(isDisplay),
        ])
    }

    private func releaseAccess(_ value: JSONValue, _ context: HostRequestContext) async throws -> JSONValue {
        let request = try value.decode(GrantIDParameters.self)
        let status: String
        do {
            try await grants.release(grantID: request.grantID, connectionID: context.connection.id)
            stopToken.stop(grantID: request.grantID)
            status = "released"
        } catch GrantStoreError.grantNotFound {
            status = "not_found"
        }
        await frames.revoke(grantIDs: [request.grantID])
        await accessibility.close(sessionID: request.grantID)
        await accessibilitySnapshots.revoke(grantID: request.grantID)
        await locks.release(grantID: request.grantID)
        await risks.revoke(connectionID: context.connection.id)
        grantMetadata.removeValue(forKey: request.grantID)
        publishedGrantIDs.remove(request.grantID)
        lastAccessibilityRevision.removeValue(forKey: request.grantID)
        maintenanceIdentityMissCounts.removeValue(forKey: request.grantID)
        await indicator.hide(grantID: request.grantID)
        return .object(["status": .string(status), "grantId": .string(request.grantID.uuidString)])
    }

    private func getState(_ value: JSONValue, _ context: HostRequestContext) async throws -> JSONValue {
        let request = try value.decode(GetStateParameters.self)
        guard (100...30_000).contains(request.timeoutMs),
              (320...4_096).contains(request.maxWidthPx),
              (1_000...200_000).contains(request.maxAccessibilityChars),
              ["inline", "resource", "none"].contains(request.screenshot) else {
            throw WireError(code: "invalid_request", message: "Invalid state request bounds")
        }
        let grant = try await grantForCapture(request.grantID, context.connection.id)
        let stateCancellation = stopToken.scope(
            connectionID: context.connection.id,
            grantID: grant.id
        )
        try await ensureStateRequestActive(grant, cancellation: stateCancellation, context: context)
        guard await actionGate.acquire(grantID: grant.id) else {
            throw WireError(
                code: "BUSY",
                message: "Another state or action operation is already running for this grant",
                retryable: true
            )
        }
        do {
        let policy = ScreenshotSizingPolicy(maxDimension: request.maxWidthPx, maxPixels: 4_000_000)
        let screenshot: ScreenshotPayload
        var accessibilityJSON: JSONValue?
        var accessibilityState: AccessibilityState?
        var target = grantMetadata[grant.id]?.target ?? .object([:])
        switch grant.scope {
        case .display(let display):
            screenshot = try await capture.captureDisplay(
                displayID: display.displayID,
                policy: policy,
                excludingProcess: context.connection.peer.captureExclusion
            )
            try await ensureStateRequestActive(grant, cancellation: stateCancellation, context: context)
            await accessibility.close(sessionID: grant.id)
            await accessibilitySnapshots.revoke(grantID: grant.id)
            try await ensureStateRequestActive(grant, cancellation: stateCancellation, context: context)
            lastAccessibilityRevision.removeValue(forKey: grant.id)
            if request.includeAccessibility {
                accessibilityJSON = .object([
                    "mode": .string("full"),
                    "nodes": .array([]),
                    "truncated": .bool(false),
                    "resetReason": .string("target_has_no_accessibility_tree"),
                ])
            }
        case .window(let identity):
            let inventory = try await capture.inventory()
            try await ensureStateRequestActive(grant, cancellation: stateCancellation, context: context)
            guard let app = inventory.applications.first(where: { $0.processID == identity.processID }),
                  let window = app.windows.first(where: { $0.identity == identity }) else {
                await stop(grantID: grant.id)
                throw WireError(code: "window_not_found", message: "Granted window is no longer available")
            }
            do {
                try await accessibility.validateWindowBinding(sessionID: grant.id, window: window)
            } catch {
                await stop(grantID: grant.id)
                throw WireError(
                    code: "WINDOW_CLOSED",
                    message: "The granted window closed or was recreated"
                )
            }
            let displayID = bestDisplay(for: window.frame, displays: inventory.displays)?.displayID ?? 0
            target = windowTargetJSON(window, app: app, displayID: displayID)
            if var metadata = grantMetadata[grant.id] { metadata.target = target; grantMetadata[grant.id] = metadata }
            screenshot = try await capture.captureWindow(
                windowID: identity.windowID,
                expectedIdentity: identity,
                policy: policy
            )
            try await ensureStateRequestActive(grant, cancellation: stateCancellation, context: context)
            if request.includeAccessibility, grant.capabilities.contains(.accessibilityRead) {
                let state = try await accessibility.state(
                    sessionID: grant.id,
                    window: window,
                    maximumNodes: 1_200,
                    maximumDepth: 64,
                    maximumCharacters: request.maxAccessibilityChars
                )
                try await ensureStateRequestActive(grant, cancellation: stateCancellation, context: context)
                lastAccessibilityRevision[grant.id] = state.revision
                accessibilityState = state
            } else {
                await accessibilitySnapshots.revoke(grantID: grant.id)
                try await ensureStateRequestActive(grant, cancellation: stateCancellation, context: context)
                let revision = try await accessibility.refreshWindowBinding(
                    sessionID: grant.id,
                    window: window
                )
                lastAccessibilityRevision[grant.id] = revision
                if request.includeAccessibility {
                    accessibilityJSON = .object([
                        "mode": .string("full"),
                        "nodes": .array([]),
                        "truncated": .bool(false),
                        "resetReason": .string("accessibility_not_granted"),
                    ])
                }
            }
        }
        try await ensureStateRequestActive(grant, cancellation: stateCancellation, context: context)
        let frame = await frames.create(
            grantID: grant.id,
            connectionID: context.connection.id,
            transform: screenshot.transform,
            accessibilityRevision: accessibilityState?.revision ?? lastAccessibilityRevision[grant.id]
        )
        do {
            try await ensureStateRequestActive(grant, cancellation: stateCancellation, context: context)
            if let accessibilityState {
                if let baseFrameID = request.sinceFrameID {
                    if let base = await accessibilitySnapshots.state(grantID: grant.id, frameID: baseFrameID) {
                        accessibilityJSON = Self.accessibilityDiffJSON(
                            current: accessibilityState,
                            base: base,
                            baseFrameID: baseFrameID
                        ) ?? Self.accessibilityJSON(accessibilityState, resetReason: "diff_unavailable")
                    } else {
                        accessibilityJSON = Self.accessibilityJSON(
                            accessibilityState,
                            resetReason: "base_frame_unavailable"
                        )
                    }
                } else {
                    accessibilityJSON = Self.accessibilityJSON(accessibilityState, resetReason: nil)
                }
                await accessibilitySnapshots.record(
                    grantID: grant.id,
                    frameID: frame.frameID,
                    state: accessibilityState
                )
            }
            // No actor suspension follows this final authority check before the
            // frame response is assembled and returned.
            try await ensureStateRequestActive(grant, cancellation: stateCancellation, context: context)
        } catch {
            await frames.revoke(grantIDs: [grant.id])
            await accessibilitySnapshots.revoke(grantID: grant.id)
            await accessibility.close(sessionID: grant.id)
            lastAccessibilityRevision.removeValue(forKey: grant.id)
            throw error
        }
        let coordinate = coordinateSpace(screenshot.transform)
        var result: [String: JSONValue] = [
            "status": .string("completed"),
            "grantId": .string(grant.id.uuidString),
            "target": target,
            "frameId": .string(frame.frameID.uuidString),
            "capturedAt": .string(Self.iso(frame.createdAt)),
            "coordinateSpace": coordinate,
        ]
        if let accessibilityJSON { result["accessibility"] = accessibilityJSON }
        if request.screenshot != "none" {
            result["screenshot"] = .object([
                "mimeType": .string("image/png"),
                "data": .string(screenshot.data),
                "width": .number(Double(screenshot.width)),
                "height": .number(Double(screenshot.height)),
                "sha256": .string(screenshot.sha256),
                "transform": coordinate,
            ])
        }
        let response = JSONValue.object(result)
        await actionGate.release(grantID: grant.id)
        return response
        } catch {
            await actionGate.release(grantID: grant.id)
            throw error
        }
    }

    private func action(_ raw: JSONValue, _ context: HostRequestContext) async throws -> JSONValue {
        let request = try raw.decode(HostActionRequest.self)
        try HostActionValidation.validate(request)
        // This fallback is used only when frame/grant validation fails before a
        // current-frame AX target can be resolved. No action is dispatched in
        // that path. Once resolution succeeds, the audit and approval tier are
        // replaced with the semantic classification below.
        var classifiedRisk = RiskClassifier.classify(request: request, element: nil)
        do {
            let actionCancellation = stopToken.scope(
                connectionID: context.connection.id,
                grantID: request.grantID
            )
            let frame = try await frames.validate(
                frameID: request.frameID,
                grantID: request.grantID,
                connectionID: context.connection.id,
                intent: request.intent
            )
            let capability = request.usesAccessibilityAction
                ? HostCapability.accessibilityAction : .syntheticInput
            let grant = try await authorizeGrant(
                grantID: request.grantID,
                connectionID: context.connection.id,
                capability: capability
            )
            if request.kind == .paste,
               !(grantMetadata[grant.id]?.publicCapabilities.isSuperset(
                    of: [.observe, .interact, .clipboardWrite]
               ) == true) {
                throw WireError(code: "ACCESS_DENIED", message: "Paste requires clipboard_write capability")
            }
            try await revalidate(grant: grant, frame: frame)

            let elementDescriptor = await semanticActionTarget(
                request: request,
                grantID: grant.id
            )
            let elementEnabled = await semanticElementEnabled(
                request: request,
                grantID: grant.id,
                frameID: frame.frameID
            )
            classifiedRisk = RiskClassifier.classify(
                request: request,
                element: elementDescriptor,
                elementEnabled: elementEnabled
            )
            // The action digest binds the wire action to its resolved semantic
            // target for audit, frame checks, and the optional legacy risk-based
            // policy. A relabelled/replaced control cannot reuse earlier frame
            // semantics.
            let bindsFocusedElementFrame = request.selector == nil
                && (request.text != nil || request.value != nil)
            let digest = try actionDigest(
                raw,
                semanticTarget: elementDescriptor,
                includeSemanticFrame: bindsFocusedElementFrame
            )
            return try await performAction(
                request: request,
                context: context,
                riskTier: classifiedRisk,
                actionDigest: digest,
                elementDescriptor: elementDescriptor,
                actionCancellation: actionCancellation,
                frame: frame,
                grant: grant
            )
        } catch {
            let mapped = WireErrorMapping.map(error)
            let result: AuditResult
            if mapped.code == "CANCELLED" { result = .canceled }
            else if mapped.code == "approval_required"
                || mapped.code.hasPrefix("APPROVAL_")
                || mapped.code == "ACCESS_DENIED"
                || mapped.code == "action_blocked" {
                result = .denied
            } else { result = .failed }
            do {
                try appendAudit(
                    request,
                    context: context,
                    riskTier: classifiedRisk,
                    result: result,
                    reasonCode: mapped.code
                )
            } catch {
                throw WireError(
                    code: "INTERNAL_ERROR",
                    message: "Audit recording failed; the action outcome may be uncertain"
                )
            }
            throw error
        }
    }

    private func performAction(
        request: HostActionRequest,
        context: HostRequestContext,
        riskTier: RiskTier,
        actionDigest digest: String,
        elementDescriptor: AccessibilityActionDescriptor?,
        actionCancellation: any InteractionCancellationChecking,
        frame: FrameResource,
        grant: AccessGrant
    ) async throws -> JSONValue {
        if riskTier == .blocked {
            throw WireError(code: "action_blocked", message: "Action is blocked by host safety policy")
        }

        // A grant-scoped session is the user's authorization for every
        // capability approved in the native picker. This avoids interrupting
        // the user before each action while keeping target, frame, capability,
        // process-identity, protected-surface, and Stop checks in force.
        var sensitiveWriteAuthorized = actionApprovalPolicy == .grantScoped
        if actionApprovalPolicy == .riskBased, riskTier > .low {
            let approvalSummary = RiskApprovalSummaryBuilder.summary(
                request: request,
                target: grantMetadata[grant.id]?.target ?? .object([:]),
                harnessName: context.connection.peer.name,
                element: elementDescriptor
            )
            if let approvalID = request.approvalRequestID {
                guard await risks.consumeApproved(
                    approvalRequestID: approvalID,
                    connectionID: context.connection.id,
                    actionDigest: digest,
                    approvalMode: request.approvalMode
                ) else { throw WireError(code: "approval_invalid", message: "Approval is expired, mismatched or consumed") }
                sensitiveWriteAuthorized = true
            } else {
                let authorization = await risks.authorize(
                    connectionID: context.connection.id,
                    requestID: context.requestID,
                    actionDigest: digest,
                    tier: riskTier,
                    approvalMode: request.approvalMode
                )
                guard case .challenge(let challenge) = authorization else {
                    throw WireError(code: "action_blocked", message: "Action is blocked")
                }
                guard challenge.approvalMode == request.approvalMode else {
                    throw WireError(code: "APPROVAL_MISMATCH", message: "Approval UX route changed for this exact action")
                }
                if request.approvalMode == .native {
                    let approvalCancellation = RelayedInteractionCancellation(
                        base: DeadlineInteractionCancellation(
                            base: actionCancellation,
                            deadline: context.deadline
                        )
                    )
                    let approved = await withTaskCancellationHandler {
                        await riskPresenter.requestApproval(
                            challenge,
                            summary: approvalSummary,
                            cancellation: approvalCancellation
                        )
                    } onCancel: {
                        approvalCancellation.cancel()
                    }
                    do {
                        try check(context)
                        try approvalCancellation.check()
                    } catch {
                        _ = await risks.resolve(
                            challengeID: challenge.id,
                            connectionID: context.connection.id,
                            approved: false,
                            approvalMode: .native
                        )
                        throw error
                    }
                    let resolution = await risks.resolve(
                        challengeID: challenge.id,
                        connectionID: context.connection.id,
                        approved: approved,
                        approvalMode: .native
                    )
                    switch resolution {
                    case let .resolved(disposition, consumed):
                        guard !consumed else {
                            throw WireError(code: "APPROVAL_USED", message: "The native approval token was already consumed")
                        }
                        let expected: RiskApprovalDisposition = approved ? .approved : .denied
                        guard disposition == expected else {
                            throw WireError(code: "APPROVAL_MISMATCH", message: "Approval decision changed for this challenge")
                        }
                    case .decisionMismatch:
                        throw WireError(code: "APPROVAL_MISMATCH", message: "Approval decision changed for this challenge")
                    case .unavailable:
                        throw WireError(code: "APPROVAL_EXPIRED", message: "The approval challenge expired before a decision")
                    }
                    if !approved {
                        try appendAudit(
                            request,
                            context: context,
                            riskTier: riskTier,
                            result: .denied,
                            reasonCode: "APPROVAL_MISMATCH"
                        )
                        return .object(["status": .string("denied"), "reason": .string("The user denied the action.")])
                    }
                }
                throw WireError(
                    code: "approval_required",
                    message: String(approvalSummary.prefix(2_000)),
                    details: .object([
                        "approvalRequestId": .string(challenge.id.uuidString),
                        "riskTier": .string(challenge.tier.rawValue),
                        "expiresAt": .string(Self.iso(challenge.expiresAt)),
                        "approvalMode": .string(request.approvalMode.rawValue),
                    ])
                )
            }
        }
        try actionCancellation.check()
        let mayPostGlobalInput = request.usesSyntheticInput || {
            if request.kind == .click, case .element? = request.selector { return true }
            return false
        }()
        guard await actionGate.acquire(
            grantID: grant.id,
            requiresGlobalSyntheticInput: mayPostGlobalInput
        ) else {
            throw WireError(
                code: "BUSY",
                message: "Another state or conflicting synthetic-input operation is already running",
                retryable: true
            )
        }
        let relayedCancellation = RelayedInteractionCancellation(base: actionCancellation)
        do {
            // A grant can outlive the frame it described. Once both the
            // per-grant and global-input leases are held, require that exact
            // frame to still be current before any semantic re-resolution or
            // dispatch. getState uses the same per-grant lease.
            _ = try await frames.validate(
                frameID: request.frameID,
                grantID: request.grantID,
                connectionID: context.connection.id,
                intent: request.intent
            )
            try await withTaskCancellationHandler {
                try await execute(
                    request,
                    grant: grant,
                    frame: frame,
                    expectedSemanticTarget: elementDescriptor,
                    sensitiveWriteAuthorized: sensitiveWriteAuthorized,
                    context: context,
                    cancellation: relayedCancellation
                )
            } onCancel: {
                relayedCancellation.cancel()
            }
            await actionGate.release(grantID: grant.id)
        } catch {
            await actionGate.release(grantID: grant.id)
            throw error
        }
        let target = grantMetadata[grant.id]?.target ?? .object([:])
        try appendAudit(
            request,
            context: context,
            riskTier: riskTier,
            result: .allowed,
            reasonCode: nil
        )
        return .object([
            "status": .string("completed"),
            "actionId": .string(UUID().uuidString),
            "grantId": .string(grant.id.uuidString),
            "target": target,
            "completedAt": .string(Self.iso(Date())),
        ])
    }

    private func approveRisk(_ value: JSONValue, _ context: HostRequestContext) async throws -> JSONValue {
        let request = try value.decode(ApproveRiskParameters.self)
        let resolution = await risks.resolve(
            challengeID: request.approvalRequestID,
            connectionID: context.connection.id,
            approved: request.approved,
            approvalMode: .elicitation
        )
        let disposition: RiskApprovalDisposition
        let consumed: Bool
        switch resolution {
        case let .resolved(resolvedDisposition, wasConsumed):
            disposition = resolvedDisposition
            consumed = wasConsumed
        case .decisionMismatch:
            throw WireError(code: "APPROVAL_MISMATCH", message: "Approval decision changed for this challenge")
        case .unavailable:
            throw WireError(code: "approval_not_found", message: "Approval request is missing or expired")
        }
        return .object([
            "approvalRequestId": .string(request.approvalRequestID.uuidString),
            "disposition": .string(disposition.rawValue),
            "consumed": .bool(consumed),
        ])
    }

    private func execute(
        _ request: HostActionRequest,
        grant: AccessGrant,
        frame: FrameResource,
        expectedSemanticTarget: AccessibilityActionDescriptor?,
        sensitiveWriteAuthorized: Bool,
        context: HostRequestContext,
        cancellation baseCancellation: InteractionCancellationChecking
    ) async throws {
        let cancellation = DeadlineInteractionCancellation(
            base: baseCancellation,
            deadline: context.deadline
        )
        try check(context)
        try cancellation.check()
        // A grant can remain open while the target changes. Revalidate
        // immediately before dispatch, not only when the request first enters
        // the action pipeline.
        try await revalidate(grant: grant, frame: frame)
        if case .window = grant.scope,
           frame.accessibilityRevision != lastAccessibilityRevision[grant.id] {
            throw WireError(
                code: "STALE_FRAME",
                message: "The frame's Accessibility revision is no longer current",
                retryable: true
            )
        }
        let requiredCapability: HostCapability = request.usesAccessibilityAction
            ? .accessibilityAction : .syntheticInput
        _ = try await authorizeGrant(
            grantID: grant.id,
            connectionID: context.connection.id,
            capability: requiredCapability
        )
        let currentSemanticTarget = await semanticActionTarget(
            request: request,
            grantID: grant.id
        )
        let bindsFocusedElementFrame = request.selector == nil
            && (request.text != nil || request.value != nil)
        guard semanticTargetMatches(
            expectedSemanticTarget,
            currentSemanticTarget,
            requireSameFrame: bindsFocusedElementFrame
        ) else {
            throw WireError(
                code: "STALE_FRAME",
                message: "The resolved accessibility control changed; refresh state before acting",
                retryable: true
            )
        }
        try cancellation.check()
        if request.usesAccessibilityAction, case .window(let identity) = grant.scope {
            try syntheticDestinationGuard.validateSemanticWindow(identity)
        }
        let input = self.input
        let textController = self.textController
        let destinationGuard = syntheticDestinationGuard
        var lease: FocusLease?
        if case .window(let identity) = grant.scope, request.usesSyntheticInput {
            lease = try focus.acquire(processID: identity.processID)
        }
        do {
            if case .window(let identity) = grant.scope, request.usesSyntheticInput {
            let inventory = try await capture.inventory()
            guard let window = inventory.applications.flatMap(\.windows).first(where: { $0.identity == identity }) else {
                throw WireError(code: "WINDOW_CLOSED", message: "The exact granted window is unavailable")
            }
            try await accessibility.raise(window: window, cancellation: cancellation)
            }
            switch request.kind {
            case .click:
                guard let selector = request.selector else { throw invalidAction("selector is required") }
                switch selector {
                case .point(let point):
                    let globalPoint = try frame.transform.globalPoint(forOutputPoint: point)
                    let button = MouseButton(publicName: request.mouseButton ?? "left")
                    let count = request.clickCount ?? 1
                    try destinationGuard.validate(
                        scope: grant.scope,
                        globalPoints: [globalPoint],
                        requireWholeTarget: false,
                        excludingProcess: context.connection.peer.captureExclusion
                    )
                    try await Task.detached {
                        try input.click(
                            globalPoint: globalPoint,
                            button: button,
                            clickCount: count,
                            cancellation: cancellation
                        )
                    }.value
                case .element(let id):
                    let resolvedID = try nodeID(id)
                    let button = MouseButton(publicName: request.mouseButton ?? "left")
                    let count = request.clickCount ?? 1
                    if ElementClickFallbackPolicy.canUseAXPress(
                        mouseButton: request.mouseButton ?? "left",
                        clickCount: count
                    ) {
                        do {
                            try await accessibility.perform(
                                sessionID: grant.id,
                                revision: try currentRevision(grant.id),
                                command: .perform(nodeID: resolvedID, action: nil),
                                cancellation: cancellation
                            )
                            break
                        } catch let error as AccessibilityError where
                            ElementClickFallbackPolicy.permitsFallback(after: error) {
                            // Continue into the same action's frame-, grant-,
                            // risk-, and semantic-target-bound public fallback.
                        }
                    }
                    try await clickElementCoordinateFallback(
                        nodeID: resolvedID,
                        button: button,
                        clickCount: count,
                        approvedDescriptor: expectedSemanticTarget,
                        grant: grant,
                        frame: frame,
                        context: context,
                        cancellation: cancellation
                    )
                }
            case .drag:
                guard case .point(let from)? = request.from, case .point(let to)? = request.to else {
                    throw invalidAction("drag requires point selectors")
                }
                let globalFrom = try frame.transform.globalPoint(forOutputPoint: from)
                let globalTo = try frame.transform.globalPoint(forOutputPoint: to)
                let duration = Double(request.durationMs ?? 500) / 1_000
                try destinationGuard.validate(
                    scope: grant.scope,
                    globalPoints: [globalFrom, globalTo],
                    requireWholeTarget: false,
                    excludingProcess: context.connection.peer.captureExclusion
                )
                let dragScope = grant.scope
                let excludedProcess = context.connection.peer.captureExclusion
                let validateDragDestination: @Sendable (Point) throws -> Void = { point in
                    // Re-read the live WindowServer stack at every event
                    // boundary. In window scope this binds the entire drag to
                    // the exact grant even if another surface appears after
                    // mouse-down; display scope applies its protected/self
                    // destination policy to the current point as well.
                    try destinationGuard.validate(
                        scope: dragScope,
                        globalPoints: [point],
                        requireWholeTarget: false,
                        excludingProcess: excludedProcess
                    )
                }
                try await Task.detached {
                    try input.drag(
                        from: globalFrom,
                        to: globalTo,
                        button: .left,
                        duration: duration,
                        cancellation: cancellation,
                        validateDestination: validateDragDestination
                    )
                }.value
            case .scroll:
                let amount = request.amount ?? 1
                let points = Int32(min(Double(Int32.max), amount * (request.unit == "lines" ? 40 : 600)))
                let delta: (Int32, Int32)
                switch request.direction {
                case "up": delta = (0, points)
                case "down": delta = (0, -points)
                case "left": delta = (points, 0)
                case "right": delta = (-points, 0)
                default: throw invalidAction("valid direction is required")
                }
                var globalPoint: Point?
                switch request.selector {
                case .point(let point):
                    globalPoint = try frame.transform.globalPoint(forOutputPoint: point)
                case .element(let id):
                    let revision = try currentRevision(grant.id)
                    let numericID = try nodeID(id)
                    try await accessibility.perform(
                        sessionID: grant.id,
                        revision: revision,
                        command: .focus(nodeID: numericID),
                        cancellation: cancellation
                    )
                    globalPoint = try await accessibility.describeActionTarget(
                        sessionID: grant.id,
                        revision: revision,
                        nodeID: numericID
                    ).frame.map { elementFrame in
                        Point(
                            x: elementFrame.origin.x + elementFrame.size.width / 2,
                            y: elementFrame.origin.y + elementFrame.size.height / 2
                        )
                    }
                case nil:
                    if case .display(let display) = grant.scope {
                        globalPoint = Point(
                            x: display.frame.origin.x + display.frame.size.width / 2,
                            y: display.frame.origin.y + display.frame.size.height / 2
                        )
                    }
                    break
                }
                if globalPoint == nil {
                    globalPoint = Point(
                        x: frame.transform.globalOrigin.x + frame.transform.sourceSize.width / 2,
                        y: frame.transform.globalOrigin.y + frame.transform.sourceSize.height / 2
                    )
                }
                try destinationGuard.validate(
                    scope: grant.scope,
                    globalPoints: globalPoint.map { [$0] } ?? [],
                    requireWholeTarget: globalPoint == nil,
                    excludingProcess: context.connection.peer.captureExclusion
                )
                try await Task.detached {
                    try input.scroll(
                        deltaX: delta.0,
                        deltaY: delta.1,
                        at: globalPoint,
                        cancellation: cancellation
                    )
                }.value
            case .pressKey:
                guard let key = request.key, let code = PublicKeyMap.code(for: key) else { throw invalidAction("unsupported key") }
                let flags = PublicKeyMap.flags(request.modifiers ?? [])
                try await validateFocusedSyntheticDestination(
                    grant: grant,
                    destinationGuard: destinationGuard,
                    excludingProcess: context.connection.peer.captureExclusion,
                    cancellation: cancellation
                )
                try await Task.detached {
                    try input.key(code: code, flags: flags, cancellation: cancellation)
                }.value
            case .typeText:
                guard let text = request.text else { throw invalidAction("text is required") }
                let interval = Double(request.intervalMs ?? 0) / 1_000
                for character in text.map(String.init) {
                    try cancellation.check()
                    try await validateFocusedSyntheticDestination(
                        grant: grant,
                        destinationGuard: destinationGuard,
                        excludingProcess: context.connection.peer.captureExclusion,
                        cancellation: cancellation
                    )
                    try await Task.detached {
                        try input.typeText(character, cancellation: cancellation)
                    }.value
                    if interval > 0 {
                        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    } else { await Task.yield() }
                }
            case .paste:
                guard let text = request.text else { throw invalidAction("text is required") }
                guard request.format == nil || request.format == "text" else {
                    throw WireError(code: "UNSUPPORTED", message: "Native paste currently supports only text format")
                }
                try await validateFocusedSyntheticDestination(
                    grant: grant,
                    destinationGuard: destinationGuard,
                    excludingProcess: context.connection.peer.captureExclusion,
                    cancellation: cancellation
                )
                try await Task.detached {
                    try textController.paste(text, cancellation: cancellation)
                }.value
            case .setValue:
                guard case .element(let id)? = request.selector, let value = request.value else {
                    throw invalidAction("element selector and value are required")
                }
                guard let expectedSemanticTarget else {
                    throw WireError(
                        code: "STALE_FRAME",
                        message: "The frame-bound Accessibility target is unavailable; refresh state",
                        retryable: true
                    )
                }
                let authorization: AccessibilityValueWriteAuthorization
                if expectedSemanticTarget.secure {
                    // Secure descendants and protected content never inherit
                    // the direct-field exception. This fact comes from the
                    // exact descriptor bound into the action digest.
                    guard AccessibilityProjection.isDirectSecureTextField(
                        role: expectedSemanticTarget.role,
                        subrole: expectedSemanticTarget.subrole
                    ), sensitiveWriteAuthorized else {
                        throw AccessibilityError.secureElement
                    }
                    authorization = .approvedDirectSecure
                } else {
                    authorization = .ordinary
                }
                try await accessibility.perform(
                    sessionID: grant.id,
                    revision: try currentRevision(grant.id),
                    command: .setValue(
                        nodeID: try nodeID(id),
                        value: value,
                        authorization: authorization
                    ),
                    cancellation: cancellation
                )
            case .selectText:
                guard case .element(let id)? = request.selector, let text = request.text else {
                    throw invalidAction("element selector and text are required")
                }
                try await accessibility.selectText(
                    sessionID: grant.id,
                    revision: try currentRevision(grant.id),
                    nodeID: try nodeID(id),
                    text: text,
                    prefix: request.prefix,
                    suffix: request.suffix,
                    selectionType: request.selectionType ?? "text",
                    cancellation: cancellation
                )
            case .performSecondaryAction:
                guard case .element(let id)? = request.selector, let action = request.action else {
                    throw invalidAction("element selector and action are required")
                }
                try await accessibility.perform(
                    sessionID: grant.id,
                    revision: try currentRevision(grant.id),
                    command: .perform(nodeID: try nodeID(id), action: action),
                    cancellation: cancellation
                )
            }
            try lease?.restore()
        } catch {
            do { try lease?.restore() } catch { throw InteractionSafetyError.focusRestoreFailed }
            throw error
        }
    }

    private func clickElementCoordinateFallback(
        nodeID: Int,
        button: MouseButton,
        clickCount: Int,
        approvedDescriptor: AccessibilityActionDescriptor?,
        grant: AccessGrant,
        frame: FrameResource,
        context: HostRequestContext,
        cancellation: InteractionCancellationChecking
    ) async throws {
        guard case .window(let identity) = grant.scope else {
            throw invalidAction("element clicks require an exact window grant")
        }
        guard let approvedDescriptor else {
            throw WireError(
                code: "ELEMENT_NOT_ACTIONABLE",
                message: "The frame-bound element could not be resolved for coordinate fallback"
            )
        }
        try check(context)
        try cancellation.check()
        // AX actions and synthetic input are separate native capabilities.
        // Re-check both the exact target and synthetic authority only when the
        // fallback is actually needed.
        try await revalidate(grant: grant, frame: frame)
        _ = try await authorizeGrant(
            grantID: grant.id,
            connectionID: context.connection.id,
            capability: .syntheticInput
        )
        let revision = try currentRevision(grant.id)
        let initialDescriptor = try await accessibility.describeActionTarget(
            sessionID: grant.id,
            revision: revision,
            nodeID: nodeID
        )
        guard ElementClickFallbackPolicy.isSameBoundTarget(initialDescriptor, as: approvedDescriptor) else {
            throw WireError(
                code: "STALE_FRAME",
                message: "The selected element changed; refresh target state before retrying",
                retryable: true
            )
        }
        let frameBounds = Rect(
            origin: frame.transform.globalOrigin,
            size: frame.transform.sourceSize
        )
        guard ElementClickFallbackPolicy.center(of: initialDescriptor, within: frameBounds) != nil else {
            throw WireError(
                code: "ELEMENT_NOT_ACTIONABLE",
                message: "The selected element has no safe center in the current frame"
            )
        }

        let fallbackLease = try focus.acquire(processID: identity.processID)
        do {
            let inventory = try await capture.inventory()
            guard let window = inventory.applications.flatMap(\.windows).first(where: {
                $0.identity == identity
            }) else {
                throw WireError(code: "WINDOW_CLOSED", message: "The exact granted window is unavailable")
            }
            try await accessibility.raise(window: window, cancellation: cancellation)
            try check(context)
            try cancellation.check()
            // Focus can change layout. Revalidate window geometry and the
            // frame-bound AX element again immediately before CGEvent.
            try await revalidate(grant: grant, frame: frame)
            let finalDescriptor = try await accessibility.describeActionTarget(
                sessionID: grant.id,
                revision: revision,
                nodeID: nodeID
            )
            guard ElementClickFallbackPolicy.isSameBoundTarget(finalDescriptor, as: approvedDescriptor),
                  let globalPoint = ElementClickFallbackPolicy.center(
                    of: finalDescriptor,
                    within: frameBounds
                  ) else {
                throw WireError(
                    code: "STALE_FRAME",
                    message: "The selected element changed; refresh target state before retrying",
                    retryable: true
                )
            }
            try syntheticDestinationGuard.validate(
                scope: grant.scope,
                globalPoints: [globalPoint],
                requireWholeTarget: false,
                excludingProcess: context.connection.peer.captureExclusion
            )
            try cancellation.check()
            let input = self.input
            try await Task.detached {
                try input.click(
                    globalPoint: globalPoint,
                    button: button,
                    clickCount: clickCount,
                    cancellation: cancellation
                )
            }.value
            try fallbackLease.restore()
        } catch {
            do { try fallbackLease.restore() } catch {
                throw InteractionSafetyError.focusRestoreFailed
            }
            throw error
        }
    }

    private func validateFocusedSyntheticDestination(
        grant: AccessGrant,
        destinationGuard: any SyntheticDestinationGuarding,
        excludingProcess: CaptureExcludedProcessIdentity?,
        cancellation: InteractionCancellationChecking
    ) async throws {
        try cancellation.check()
        switch grant.scope {
        case .window:
            try await accessibility.validateFocusedWindow(
                sessionID: grant.id,
                revision: try currentRevision(grant.id)
            )
            try destinationGuard.validate(
                scope: grant.scope,
                globalPoints: [],
                requireWholeTarget: true,
                excludingProcess: excludingProcess
            )
        case .display:
            // Display grants are session-only but still may not send keyboard
            // input into a protected or off-display focused window.
            try destinationGuard.validate(
                scope: grant.scope,
                globalPoints: [],
                requireWholeTarget: true,
                excludingProcess: excludingProcess
            )
        }
        try cancellation.check()
    }

    private func check(_ context: HostRequestContext) throws {
        guard Date() < context.deadline else { throw WireError(code: "deadline_exceeded", message: "Request deadline elapsed") }
        guard !revokingConnections.contains(context.connection.id) else {
            throw WireError(code: "connection_revoked", message: "Connection is being revoked")
        }
        if Task.isCancelled { throw InputDriverError.canceled }
    }

    private func grantForCapture(_ id: UUID, _ connectionID: UUID) async throws -> AccessGrant {
        do {
            return try await authorizeGrant(
                grantID: id,
                connectionID: connectionID,
                capability: .windowCapture
            )
        } catch GrantStoreError.capabilityDenied {
            return try await authorizeGrant(
                grantID: id,
                connectionID: connectionID,
                capability: .displayCapture
            )
        }
    }

    private func ensureStateRequestActive(
        _ grant: AccessGrant,
        cancellation: InteractionCancellationChecking,
        context: HostRequestContext
    ) async throws {
        try check(context)
        try cancellation.check()
        let capability: HostCapability
        switch grant.scope {
        case .window: capability = .windowCapture
        case .display: capability = .displayCapture
        }
        _ = try await authorizeGrant(
            grantID: grant.id,
            connectionID: context.connection.id,
            capability: capability
        )
        try check(context)
        try cancellation.check()
    }

    private func authorizeGrant(
        grantID: UUID,
        connectionID: UUID,
        capability: HostCapability
    ) async throws -> AccessGrant {
        try await requireAppControlEnabled()
        guard publishedGrantIDs.contains(grantID) else { throw GrantStoreError.grantNotFound }
        do {
            return try await grants.authorize(
                grantID: grantID,
                connectionID: connectionID,
                capability: capability
            )
        } catch GrantStoreError.grantExpired {
            await stop(grantID: grantID)
            throw GrantStoreError.grantExpired
        }
    }

    private func requireAppControlEnabled() async throws {
        guard await controlPolicy.isAppControlEnabled() else {
            throw WireError(
                code: "APP_CONTROL_DISABLED",
                message: "General app access is off in Jules Marvine Computer Use settings"
            )
        }
    }

    private func mapCapabilities(_ publicSet: Set<PublicCapability>, display: Bool) -> Set<HostCapability> {
        var result: Set<HostCapability> = []
        if publicSet.contains(.observe) {
            result.insert(display ? .displayCapture : .windowCapture)
            if !display { result.insert(.accessibilityRead) }
        }
        if publicSet.contains(.interact) {
            result.insert(.syntheticInput)
            if !display { result.insert(.accessibilityAction) }
        }
        if publicSet.contains(.clipboardWrite) { result.insert(.syntheticInput) }
        return result
    }

    private func matchingApps(_ selector: ApplicationSelector, in apps: [ApplicationDescriptor]) -> [ApplicationDescriptor] {
        switch selector.kind {
        case .bundleID: return apps.filter { $0.bundleIdentifier == selector.value }
        case .name: return apps.filter { $0.name.localizedCaseInsensitiveCompare(selector.value) == .orderedSame }
        case .path:
            let expectedPath = URL(fileURLWithPath: selector.value)
                .resolvingSymlinksInPath()
                .standardizedFileURL.path
            return apps.filter { $0.bundleURLPath == expectedPath }
        }
    }

    private func launchAndFind(
        _ selector: ApplicationSelector,
        candidate: ApplicationLaunchCandidate,
        context: HostRequestContext,
        cancellation: InteractionCancellationChecking
    ) async throws -> [ApplicationDescriptor] {
        try await applicationLauncher.launch(candidate)
        // Application launch completion does not imply that ScreenCaptureKit
        // can already inventory the app's first window. Poll for a bounded
        // interval while honoring the request's human-scale deadline and its
        // connection/grant cancellation generation.
        let pollDeadline = min(context.deadline, Date().addingTimeInterval(5))
        repeat {
            try check(context)
            try cancellation.check()
            let applications = matchingApps(selector, in: try await capture.inventory().applications)
            try check(context)
            try cancellation.check()
            if !applications.isEmpty { return applications }
            guard Date() < pollDeadline else { return [] }
            try await Task.sleep(nanoseconds: 100_000_000)
        } while true
    }

    private func displayJSON(_ display: DisplayIdentity) -> JSONValue {
        .object([
            "displayId": .string(Self.publicDisplayID(display.displayID)),
            "name": .string(display.name),
            "isMain": .bool(display.isMain),
            "isMirrored": .bool(display.isMirrored),
            "framePoints": rectJSON(display.frame),
            "pixelWidth": .number(display.pixelSize.width),
            "pixelHeight": .number(display.pixelSize.height),
            "scaleFactor": .number(display.pointPixelScale),
        ])
    }

    private func windowTargetJSON(_ window: WindowDescriptor, app: ApplicationDescriptor, displayID: UInt32) -> JSONValue {
        var appMetadata: [String: JSONValue] = [
            "bundleId": .string(app.bundleIdentifier),
            "name": .string(app.name),
            "pid": .number(Double(app.processID)),
        ]
        if let bundlePath = app.bundleURLPath {
            let canonicalBundlePath = URL(fileURLWithPath: bundlePath)
                .resolvingSymlinksInPath()
                .standardizedFileURL.path
            appMetadata["bundlePath"] = .string(canonicalBundlePath)
        }
        var object: [String: JSONValue] = [
            "kind": .string("window"),
            "app": .object(appMetadata),
            "boundsPoints": rectJSON(window.frame),
            "displayId": .string(Self.publicDisplayID(displayID)),
        ]
        if let title = window.title { object["title"] = .string(title) }
        return .object(object)
    }

    private func rectJSON(_ rect: Rect) -> JSONValue {
        .object([
            "x": .number(rect.origin.x), "y": .number(rect.origin.y),
            "width": .number(rect.size.width), "height": .number(rect.size.height),
        ])
    }

    private func coordinateSpace(_ transform: ScreenshotTransform) -> JSONValue {
        .object([
            "widthPx": .number(transform.outputSize.width),
            "heightPx": .number(transform.outputSize.height),
            "globalBoundsPoints": rectJSON(Rect(origin: transform.globalOrigin, size: transform.sourceSize)),
            "imageToGlobal": affineJSON(transform.imageToGlobal),
            "globalToImage": affineJSON(transform.globalToImage),
        ])
    }

    private func affineJSON(_ value: AffineTransform2D) -> JSONValue {
        .object([
            "a": .number(value.m11), "b": .number(value.m12),
            "c": .number(value.m21), "d": .number(value.m22),
            "tx": .number(value.tx), "ty": .number(value.ty),
        ])
    }

    private func bestDisplay(for rect: Rect, displays: [DisplayIdentity]) -> DisplayIdentity? {
        displays.max { left, right in
            left.frame.cgRect.intersection(rect.cgRect).area < right.frame.cgRect.intersection(rect.cgRect).area
        }
    }

    private func semanticActionTarget(
        request: HostActionRequest,
        grantID: UUID
    ) async -> AccessibilityActionDescriptor? {
        guard let revision = lastAccessibilityRevision[grantID] else { return nil }
        if case .element(let opaque)? = request.selector,
           let resolvedID = try? nodeID(opaque) {
            return try? await accessibility.describeActionTarget(
                sessionID: grantID,
                revision: revision,
                nodeID: resolvedID
            )
        }
        guard request.text != nil || request.value != nil else { return nil }
        // Typed and pasted actions have no selector. Use only the unique,
        // frame-bound focused AX node. Ambiguity returns nil and therefore
        // keeps the conservative, metadata-free risk tier.
        return try? await accessibility.describeFocusedActionTarget(
            sessionID: grantID,
            revision: revision
        )
    }

    /// Returns only the enabled state bound to the exact frame that supplied an
    /// element selector or one unambiguous focused text target. Unknown,
    /// omitted, or ambiguous state stays nil and cannot qualify for a low-risk
    /// semantic fast path.
    private func semanticElementEnabled(
        request: HostActionRequest,
        grantID: UUID,
        frameID: UUID
    ) async -> Bool? {
        guard let state = await accessibilitySnapshots.state(
            grantID: grantID,
            frameID: frameID
        ) else { return nil }
        if case .element(let opaque)? = request.selector,
           let resolvedID = try? nodeID(opaque) {
            return state.nodes.first(where: { $0.id == resolvedID })?.isEnabled
        }
        guard request.text != nil || request.value != nil else { return nil }
        let focused = state.nodes.filter(\.isFocused)
        guard focused.count == 1 else { return nil }
        return focused[0].isEnabled
    }

    private func semanticTargetMatches(
        _ expected: AccessibilityActionDescriptor?,
        _ current: AccessibilityActionDescriptor?,
        requireSameFrame: Bool
    ) -> Bool {
        switch (expected, current) {
        case (nil, nil):
            return true
        case let (expected?, current?):
            return expected.hasSameControlSemantics(as: current)
                && (!requireSameFrame || expected.frame == current.frame)
        default:
            return false
        }
    }

    private func actionDigest(
        _ raw: JSONValue,
        semanticTarget: AccessibilityActionDescriptor?,
        includeSemanticFrame: Bool
    ) throws -> String {
        var object = raw.objectValue ?? [:]
        object.removeValue(forKey: "approvalMode")
        object.removeValue(forKey: "approvalRequestId")
        if let semanticTarget {
            // Hash semantic strings into the digest, but never place them in
            // the stored challenge or metadata-only audit record.
            object["_resolvedAXTarget"] = .object([
                "role": .string(semanticTarget.role),
                "subrole": semanticTarget.subrole.map(JSONValue.string) ?? .null,
                "title": semanticTarget.title.map(JSONValue.string) ?? .null,
                "label": semanticTarget.label.map(JSONValue.string) ?? .null,
                "identifier": semanticTarget.identifier.map(JSONValue.string) ?? .null,
                "help": semanticTarget.help.map(JSONValue.string) ?? .null,
                "placeholder": semanticTarget.placeholder.map(JSONValue.string) ?? .null,
                "context": .array(semanticTarget.semanticContext.map(JSONValue.string)),
                "secure": .bool(semanticTarget.secure),
                "actions": .array(semanticTarget.actions.sorted().map(JSONValue.string)),
            ])
            if includeSemanticFrame, let frame = semanticTarget.frame {
                object["_resolvedAXTargetFrame"] = .object([
                    "x": .number(frame.origin.x),
                    "y": .number(frame.origin.y),
                    "width": .number(frame.size.width),
                    "height": .number(frame.size.height),
                ])
            } else {
                object["_resolvedAXTargetFrame"] = .null
            }
        } else {
            object["_resolvedAXTarget"] = .null
            object["_resolvedAXTargetFrame"] = .null
        }
        let data = try JSONEncoder.wire.encode(JSONValue.object(object))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func revalidate(grant: AccessGrant, frame: FrameResource) async throws {
        let inventory = try await capture.inventory()
        switch grant.scope {
        case .window(let granted):
            let windows = inventory.applications.flatMap(\.windows)
            guard let current = windows.first(where: { $0.identity.windowID == granted.windowID }) else {
                await stop(grantID: grant.id)
                throw WireError(code: "WINDOW_CLOSED", message: "The granted window closed or was recreated")
            }
            guard current.identity == granted else {
                await stop(grantID: grant.id)
                throw WireError(code: "WINDOW_CLOSED", message: "The granted window identity changed")
            }
            do {
                try await accessibility.validateWindowBinding(sessionID: grant.id, window: current)
            } catch {
                await stop(grantID: grant.id)
                throw WireError(code: "WINDOW_CLOSED", message: "The granted window closed or was recreated")
            }
            guard protectedPolicy.evaluate(current).allowed else {
                await stop(grantID: grant.id)
                throw WireError(code: "ACCESS_DENIED", message: "The current window became protected")
            }
            guard Self.framesEqual(current.frame, Rect(origin: frame.transform.globalOrigin, size: frame.transform.sourceSize)) else {
                throw WireError(code: "STALE_FRAME", message: "The window moved or resized; refresh state", retryable: true)
            }
        case .display(let granted):
            guard let current = inventory.displays.first(where: { $0.displayID == granted.displayID }) else {
                await stop(grantID: grant.id)
                throw WireError(code: "WINDOW_CLOSED", message: "The granted display is no longer available")
            }
            let frameBounds = Rect(origin: frame.transform.globalOrigin, size: frame.transform.sourceSize)
            guard current.frame == granted.frame, Self.framesEqual(current.frame, frameBounds),
                  current.pixelSize == granted.pixelSize else {
                throw WireError(code: "STALE_FRAME", message: "Display geometry changed; refresh state", retryable: true)
            }
        }
    }

    private func currentRevision(_ grantID: UUID) throws -> UInt64 {
        guard let revision = lastAccessibilityRevision[grantID] else {
            throw WireError(code: "stale_frame", message: "Refresh accessibility state before acting")
        }
        return revision
    }

    private func nodeID(_ opaque: String) throws -> Int {
        guard opaque.hasPrefix("element-"), let id = Int(opaque.dropFirst("element-".count)) else {
            throw invalidAction("invalid element selector")
        }
        return id
    }

    private func appendAudit(
        _ request: HostActionRequest,
        context: HostRequestContext,
        riskTier: RiskTier,
        result: AuditResult,
        reasonCode: String?
    ) throws {
        guard let auditStore else { return }
        try auditStore.append(AuditEvent(
            timestamp: Date(), connectionID: context.connection.id, requestID: context.requestID,
            action: request.kind.rawValue, riskTier: riskTier, result: result,
            reasonCode: reasonCode, target: grantMetadata[request.grantID]?.auditTarget
        ))
    }

    private static func auditTarget(for scope: GrantScope, redactor: AuditRedactor) -> AuditTarget {
        switch scope {
        case .window(let window):
            return AuditTarget(
                bundleIdentifier: redactor.redact(window.bundleIdentifier),
                title: nil,
                windowID: window.windowID,
                displayID: nil
            )
        case .display(let display):
            return AuditTarget(
                bundleIdentifier: redactor.redact("display"),
                title: nil,
                windowID: nil,
                displayID: display.displayID
            )
        }
    }

    private func required(_ value: JSONValue?) throws -> JSONValue {
        guard let value else { throw WireError(code: "invalid_request", message: "params are required") }
        return value
    }

    private func invalidAction(_ message: String) -> WireError {
        WireError(code: "invalid_action", message: message)
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private static func publicDisplayID(_ id: UInt32) -> String { "display-\(id)" }
    private static func parseDisplayID(_ value: String) -> UInt32? {
        guard value.hasPrefix("display-") else { return nil }
        return UInt32(value.dropFirst("display-".count))
    }
    private static func framesEqual(_ lhs: Rect, _ rhs: Rect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 0.01 && abs(lhs.origin.y - rhs.origin.y) < 0.01 &&
            abs(lhs.size.width - rhs.size.width) < 0.01 && abs(lhs.size.height - rhs.size.height) < 0.01
    }

    static func accessibilityJSON(_ state: AccessibilityState, resetReason: String?) -> JSONValue {
        let included = Set(state.nodes.map(\.id))
        let children = Dictionary(grouping: state.nodes.compactMap { node -> (Int, Int)? in
            guard let parent = node.parentID, included.contains(parent) else { return nil }
            return (parent, node.id)
        }, by: \.0).mapValues { $0.map(\.1).sorted() }
        let nodes = state.nodes.map { accessibilityNodeJSON($0, included: included, children: children) }
        var object: [String: JSONValue] = [
            "mode": .string("full"),
            "nodes": .array(nodes),
            "truncated": .bool(state.truncated),
        ]
        if let resetReason { object["resetReason"] = .string(resetReason) }
        return .object(object)
    }

    /// Returns a deterministic, bounded diff, or nil when a full reset is
    /// required. Ordering is lexical by public element ID to match the strict
    /// MCP schema rather than relying on AX traversal or Dictionary order.
    static func accessibilityDiffJSON(
        current: AccessibilityState,
        base: AccessibilityState,
        baseFrameID: UUID,
        maximumChanges: Int = 1_200
    ) -> JSONValue? {
        guard !current.truncated, !base.truncated else { return nil }

        let currentByID = Dictionary(uniqueKeysWithValues: current.nodes.map { ($0.id, $0) })
        let baseByID = Dictionary(uniqueKeysWithValues: base.nodes.map { ($0.id, $0) })
        let currentIDs = Set(currentByID.keys)
        let baseIDs = Set(baseByID.keys)
        let children = Dictionary(grouping: current.nodes.compactMap { node -> (Int, Int)? in
            guard let parent = node.parentID, currentIDs.contains(parent) else { return nil }
            return (parent, node.id)
        }, by: \.0).mapValues { $0.map(\.1).sorted() }
        let baseChildren = Dictionary(grouping: base.nodes.compactMap { node -> (Int, Int)? in
            guard let parent = node.parentID, baseIDs.contains(parent) else { return nil }
            return (parent, node.id)
        }, by: \.0).mapValues { $0.map(\.1).sorted() }

        let changedIDs = currentIDs.filter { id in
            guard let currentNode = currentByID[id] else { return false }
            guard let baseNode = baseByID[id] else { return true }
            return accessibilityNodeJSON(currentNode, included: currentIDs, children: children) !=
                accessibilityNodeJSON(baseNode, included: baseIDs, children: baseChildren)
        }.sorted { "element-\($0)" < "element-\($1)" }
        let removedIDs = baseIDs.subtracting(currentIDs)
            .map { "element-\($0)" }
            .sorted()
        guard changedIDs.count + removedIDs.count <= maximumChanges else { return nil }

        let upserted = changedIDs.compactMap { id -> JSONValue? in
            guard let node = currentByID[id] else { return nil }
            return accessibilityNodeJSON(node, included: currentIDs, children: children)
        }
        return .object([
            "mode": .string("diff"),
            "baseFrameId": .string(baseFrameID.uuidString),
            "upsertedNodes": .array(upserted),
            "removedElementIds": .array(removedIDs.map(JSONValue.string)),
            "truncated": .bool(false),
        ])
    }

    private static func accessibilityNodeJSON(
        _ node: AccessibilityNodeSnapshot,
        included: Set<Int>,
        children: [Int: [Int]]
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "elementId": .string("element-\(node.id)"),
            "childElementIds": .array((children[node.id] ?? []).map { .string("element-\($0)") }),
            "depth": .number(Double(node.depth)),
            "role": .string(node.role),
            "focused": .bool(node.isFocused),
            "secure": .bool(node.secure),
            "actions": .array(node.actions.map(JSONValue.string)),
        ]
        if let parent = node.parentID, included.contains(parent) {
            object["parentElementId"] = .string("element-\(parent)")
        }
        if let value = node.subrole { object["subrole"] = .string(value) }
        if let value = node.title { object["title"] = .string(value) }
        if let value = node.label { object["label"] = .string(value) }
        if let value = node.value { object["value"] = .string(value) }
        if let value = node.frame {
            object["framePoints"] = .object([
                "x": .number(value.origin.x), "y": .number(value.origin.y),
                "width": .number(value.size.width), "height": .number(value.size.height),
            ])
        }
        if let value = node.isEnabled { object["enabled"] = .bool(value) }
        if let value = node.isSelected { object["selected"] = .bool(value) }
        return .object(object)
    }
}

private extension PermissionState {
    var publicName: String { self == .granted ? "authorized" : "denied" }
}

private extension HostActionKind {
    var requiresAccessibility: Bool {
        switch self {
        case .setValue, .selectText, .performSecondaryAction: return true
        default: return false
        }
    }
}

private extension HostActionRequest {
    var usesAccessibilityAction: Bool {
        if kind.requiresAccessibility { return true }
        if kind == .click, case .element? = selector { return true }
        return false
    }

    var usesSyntheticInput: Bool { !usesAccessibilityAction }
}

public enum RiskClassifier {
    /// Classifies the exact validated request using current-frame AX semantics.
    /// Caller intent remains useful evidence, but it can never downgrade the
    /// risk implied by the resolved control or by the action payload shape.
    public static func classify(
        request: HostActionRequest,
        element: AccessibilityActionDescriptor?,
        elementEnabled: Bool? = nil
    ) -> RiskTier {
        classify(
            kind: request.kind,
            intent: request.intent,
            selector: request.selector,
            mouseButton: request.mouseButton,
            clickCount: request.clickCount,
            key: request.key,
            modifiers: request.modifiers ?? [],
            text: request.text,
            value: request.value,
            semanticAction: request.action,
            element: element,
            elementEnabled: elementEnabled
        )
    }

    /// Compatibility overload used by pure callers that do not yet have a
    /// frame-bound AX descriptor. Its result intentionally stays conservative.
    public static func classify(
        kind: HostActionKind,
        intent: String,
        key: String?,
        modifiers: [String]
    ) -> RiskTier {
        classify(
            kind: kind,
            intent: intent,
            selector: nil,
            mouseButton: nil,
            clickCount: nil,
            key: key,
            modifiers: modifiers,
            text: nil,
            value: nil,
            semanticAction: nil,
            element: nil,
            elementEnabled: nil
        )
    }

    private static func classify(
        kind: HostActionKind,
        intent: String,
        selector: ActionSelector?,
        mouseButton: String?,
        clickCount: Int?,
        key: String?,
        modifiers: [String],
        text: String?,
        value: String?,
        semanticAction: String?,
        element: AccessibilityActionDescriptor?,
        elementEnabled: Bool?
    ) -> RiskTier {
        let controlEvidence = (element?.semanticMetadata ?? [])
            + (element?.actions ?? [])
            + [semanticAction].compactMap { $0 }
        let nonPayloadEvidence = normalizedEvidence([intent] + controlEvidence)
        let controlOnlyEvidence = normalizedEvidence(controlEvidence)

        if containsAnyPhrase(blockedPhrases, in: nonPayloadEvidence) {
            return .blocked
        }

        // A secure role is high risk even if a buggy or adversarial caller
        // supplies a benign intent and even if the AX description is redacted.
        if element?.secure == true || isSecureRole(element?.role) || isSecureRole(element?.subrole) {
            return .high
        }

        if containsAnyPhrase(highImpactPhrases, in: nonPayloadEvidence)
            || containsAnyFragment(highImpactFragments, in: nonPayloadEvidence.tokens) {
            return .high
        }

        if kind == .pressKey, isConsequentialKey(key, modifiers: modifiers) {
            return .high
        }
        if kind == .typeText, text?.contains(where: { $0 == "\n" || $0 == "\r" }) == true {
            // Unlike paste/set-value, synthetic typing of a line break can
            // activate a focused default control and submit the current form.
            return .high
        }
        if [.typeText, .paste, .setValue].contains(kind),
           payloadLooksSensitive(text ?? value ?? "") {
            return .high
        }

        if kind == .pressKey, isBenignNavigationKey(key, modifiers: modifiers) {
            return .low
        }

        if isClearlyBenignSemanticAction(
            kind: kind,
            selector: selector,
            mouseButton: mouseButton,
            clickCount: clickCount,
            requestedAction: semanticAction,
            element: element,
            elementEnabled: elementEnabled,
            affirmativelyBenign: containsAnyPhrase(
                benignInteractionPhrases,
                in: controlOnlyEvidence
            )
        ) {
            return .low
        }

        switch kind {
        case .scroll:
            return .low
        case .click, .drag, .pressKey, .typeText, .paste, .setValue,
             .selectText, .performSecondaryAction:
            // Coordinates, unresolved AX targets, text mutation and unknown AX
            // actions all retain the existing medium confirmation floor.
            return .medium
        }
    }

    private struct NormalizedEvidence {
        let text: String
        let tokens: [String]
    }

    private static let blockedPhrases = [
        "bypass security", "disable security", "turn off security", "turn off firewall",
        "evade approval", "skip approval", "steal credential", "exfiltrate credential",
        "approve administrator", "approve admin prompt",
    ]

    private static let highImpactPhrases = [
        // Destructive or irreversible actions.
        "delete", "delete account", "erase", "remove", "trash", "clear all",
        "discard changes", "permanently delete", "empty trash",
        // Communication, submission and publication.
        "submit", "send", "send message", "post", "publish", "reply", "comment",
        "share", "invite", "message", "email", "transmit", "export data",
        // Payments and other financial commitments.
        "payment", "pay now", "purchase", "buy", "checkout", "place order",
        "transfer money", "wire transfer", "donate", "subscribe", "billing",
        "credit card", "debit card", "card number", "bank account", "routing number", "cvv",
        // Uploads, software changes, permission changes and OS settings.
        "upload", "attach file", "install", "uninstall", "update now",
        "grant permission", "allow access", "authorize access", "privacy setting",
        "security setting", "system setting", "system preferences", "screen recording",
        "accessibility permission", "administrator password",
        // Credentials, identity and sensitive-data handling.
        "credential", "password", "passcode", "one time code", "verification code",
        "recovery code", "security code", "authentication code", "api key", "private key",
        "secret", "otp", "mfa", "two factor", "2fa", "pin",
        "sign in", "log in", "login", "auth", "authenticate", "authentication",
        "verify identity", "social security", "passport",
        "confidential", "sensitive", "sensitive data",
        // Medical actions and protected health information.
        "medical", "prescription", "diagnosis", "treatment", "medication", "dosage",
        "patient", "health record", "clinical",
    ]

    /// AX identifiers and action names are commonly glued together (for
    /// example `AXDelete` or `submitButton`). Restrict fragment matching to
    /// unambiguous consequential stems; ambiguous words such as `post` and
    /// `pin` remain phrase/token matches to avoid `postal`/`spinning` errors.
    private static let highImpactFragments = [
        "delete", "erase", "remove", "submit", "send", "publish", "message",
        "communicat", "payment", "purchase", "checkout", "upload", "install",
        "uninstall", "permission", "authorize", "credential", "password",
        "passcode", "secret", "login", "authenticat", "sensitive", "medical",
        "prescrib", "diagnosis", "transmit",
    ]

    /// A missing consequential keyword is not proof of safety: applications
    /// can expose generic labels such as Confirm or Continue. Generic AXPress
    /// and mutation fast paths therefore require affirmative, non-payload
    /// evidence of a routine navigation, fixture, search, or draft/profile
    /// operation. Unknown semantics retain the confirmation floor.
    private static let benignInteractionPhrases = [
        "harmless", "fixture", "search", "filter", "find", "query",
        "username", "user name", "display name", "profile", "note", "draft",
        "expand", "collapse", "show details", "hide details", "refresh", "reload",
        "go back", "go forward", "previous", "next", "open", "close", "cancel",
        "toggle", "increment", "decrement", "play", "pause",
    ]

    private static func normalizedEvidence(_ values: [String]) -> NormalizedEvidence {
        let folded = values.joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let tokens = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return NormalizedEvidence(text: " " + tokens.joined(separator: " ") + " ", tokens: tokens)
    }

    private static func containsAnyPhrase(
        _ phrases: [String],
        in evidence: NormalizedEvidence
    ) -> Bool {
        phrases.contains { phrase in
            let normalized = normalizedEvidence([phrase]).text
            return evidence.text.contains(normalized)
        }
    }

    private static func containsAnyFragment(_ fragments: [String], in tokens: [String]) -> Bool {
        tokens.contains { token in fragments.contains(where: token.contains) }
    }

    private static func isSecureRole(_ role: String?) -> Bool {
        guard let role else { return false }
        let normalized = role.lowercased()
        return normalized.contains("securetextfield") || normalized.contains("protectedcontent")
    }

    private static func isConsequentialKey(_ key: String?, modifiers: [String]) -> Bool {
        let normalizedKey = key?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if ["delete", "backspace", "return", "enter"].contains(normalizedKey) { return true }
        let normalizedModifiers = Set(modifiers.map { $0.lowercased() })
        return normalizedModifiers.contains("command") && ["q", "w", "return", "enter"].contains(normalizedKey)
    }

    private static func isClearlyBenignSemanticAction(
        kind: HostActionKind,
        selector: ActionSelector?,
        mouseButton: String?,
        clickCount: Int?,
        requestedAction: String?,
        element: AccessibilityActionDescriptor?,
        elementEnabled: Bool?,
        affirmativelyBenign: Bool
    ) -> Bool {
        guard let element, !element.secure else { return false }
        let role = element.role.lowercased()
        switch kind {
        case .selectText:
            return role.contains("text") || role == "axwebarea"
        case .click:
            guard case .element? = selector,
                  elementEnabled == true,
                  (mouseButton ?? "left") == "left",
                  (clickCount ?? 1) == 1,
                  element.semanticLabel != nil else { return false }
            let intrinsicallyNavigational = ["axdisclosuretriangle", "axscrollbar"].contains(role)
            return (intrinsicallyNavigational || affirmativelyBenign)
                && element.actions.contains { $0.caseInsensitiveCompare("AXPress") == .orderedSame }
        case .setValue:
            guard elementEnabled == true,
                  element.semanticLabel != nil,
                  affirmativelyBenign,
                  isOrdinaryEditableRole(role) else { return false }
            // AXValue is a settable accessibility attribute, not an action.
            // AppKit text fields commonly advertise AXConfirm/AXShowMenu only;
            // execution still verifies that AXValue is settable and fails
            // closed when it is not.
            return true
        case .typeText, .paste:
            guard elementEnabled == true,
                  element.semanticLabel != nil,
                  affirmativelyBenign,
                  isOrdinaryTextRole(role) else { return false }
            return true
        case .performSecondaryAction:
            guard let requestedAction else { return false }
            let allowed = Set(["axshowmenu", "axraise"])
            let normalizedAction = requestedAction.lowercased()
            return allowed.contains(normalizedAction)
                && element.actions.contains { $0.lowercased() == normalizedAction }
        default:
            return false
        }
    }

    private static func isOrdinaryTextRole(_ role: String) -> Bool {
        ["axtextfield", "axtextarea", "axsearchfield", "axcombobox"].contains(role)
    }

    private static func isOrdinaryEditableRole(_ role: String) -> Bool {
        isOrdinaryTextRole(role) || ["axslider", "axcheckbox", "axpopupbutton"].contains(role)
    }

    private static func isBenignNavigationKey(_ key: String?, modifiers: [String]) -> Bool {
        guard modifiers.isEmpty else { return false }
        let normalized = key?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return [
            "tab", "escape", "esc",
            "up", "arrow_up", "down", "arrow_down",
            "left", "arrow_left", "right", "arrow_right",
            "page_up", "pageup", "page_down", "pagedown", "home", "end",
        ].contains(normalized)
    }

    private static func payloadLooksSensitive(_ payload: String) -> Bool {
        guard !payload.isEmpty else { return false }
        let normalized = payload.lowercased()
        let markers = [
            "-----begin private key-----", "authorization: bearer ", "password=", "passwd=",
            "api_key", "api-key", "apikey", "client_secret", "recovery code", "secret=",
        ]
        if markers.contains(where: normalized.contains) { return true }
        if normalized.range(
            of: #"(^|[^0-9])[0-9]{3}-[0-9]{2}-[0-9]{4}([^0-9]|$)"#,
            options: .regularExpression
        ) != nil { return true }
        if normalized.range(
            of: #"(^|[^A-Za-z0-9_-])[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}([^A-Za-z0-9_-]|$)"#,
            options: .regularExpression
        ) != nil { return true }
        return containsLuhnValidCardNumber(normalized)
    }

    private static func containsLuhnValidCardNumber(_ value: String) -> Bool {
        var candidate: [Int] = []
        func isLuhnValid(_ digits: [Int]) -> Bool {
            guard (13...19).contains(digits.count), Set(digits).count > 1 else { return false }
            let checksum = digits.reversed().enumerated().reduce(0) { total, item in
                let (offset, digit) = item
                guard offset % 2 == 1 else { return total + digit }
                let doubled = digit * 2
                return total + (doubled > 9 ? doubled - 9 : doubled)
            }
            return checksum % 10 == 0
        }
        for scalar in value.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar),
               let digit = Int(String(scalar)) {
                candidate.append(digit)
                if candidate.count > 19 { candidate.removeAll(keepingCapacity: true) }
            } else if (scalar == " " || scalar == "-") && !candidate.isEmpty {
                continue
            } else {
                if isLuhnValid(candidate) { return true }
                candidate.removeAll(keepingCapacity: true)
            }
        }
        return isLuhnValid(candidate)
    }
}

private extension MouseButton {
    init(publicName: String) {
        switch publicName {
        case "right": self = .right
        case "middle": self = .center
        default: self = .left
        }
    }
}

public enum PublicKeyMap {
    /// The complete named-key vocabulary advertised by the MCP schema. Values
    /// are macOS virtual key codes, not Unicode characters.
    public static let namedKeyCodes: [String: UInt16] = [
        "return": 36, "enter": 36,
        "tab": 48, "space": 49,
        "backspace": 51, "delete": 51,
        "escape": 53, "esc": 53,
        "clear": 71,
        "help": 114, "insert": 114,
        "home": 115,
        "page_up": 116, "pageup": 116,
        "forward_delete": 117, "forwarddelete": 117,
        "end": 119,
        "page_down": 121, "pagedown": 121,
        "left": 123, "arrow_left": 123,
        "right": 124, "arrow_right": 124,
        "down": 125, "arrow_down": 125,
        "up": 126, "arrow_up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118,
        "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "f13": 105, "f14": 107, "f15": 113, "f16": 106,
        "f17": 64, "f18": 79, "f19": 80, "f20": 90,
    ]

    public static func code(for key: String) -> UInt16? {
        if let value = namedKeyCodes[key] { return value }
        let ansi: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
            "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
            "n": 45, "m": 46, ".": 47, "`": 50,
        ]
        // The API models a physical key plus explicit modifiers. Accepting an
        // uppercase letter without adding Shift would silently emit lowercase.
        guard key.count == 1, key == key.lowercased(), let character = key.first else { return nil }
        return ansi[character]
    }

    public static func flags(_ modifiers: [String]) -> UInt64 {
        modifiers.reduce(0) { result, modifier in
            switch modifier {
            case "command": return result | KeyboardModifier.command
            case "control": return result | KeyboardModifier.control
            case "option": return result | KeyboardModifier.option
            case "shift": return result | KeyboardModifier.shift
            case "function": return result | CGEventFlags.maskSecondaryFn.rawValue
            default: return result
            }
        }
    }
}

private extension CGRect {
    var area: Double { isNull || isInfinite ? 0 : width * height }
}
