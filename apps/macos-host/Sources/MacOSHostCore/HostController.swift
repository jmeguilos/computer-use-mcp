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
    public let reason: String
    public let candidates: [GrantChoice]
    public let capabilities: Set<PublicCapability>
    public let displayTarget: Bool
    public let appConsentExists: Bool
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
    public let appName: String
    public let bundleIdentifier: String
    public let reason: String
    public let capabilities: Set<PublicCapability>
}

public protocol AccessApprovalPresenting: Sendable {
    /// Separate consent boundary for a state-changing launch. This happens
    /// before NSWorkspace is asked to start an absent application; the later
    /// exact-window picker remains mandatory.
    func requestLaunchApproval(_ request: LaunchApprovalRequest) async -> Bool
    func requestApproval(_ request: AccessApprovalRequest) async -> AccessApprovalDecision
}

public extension AccessApprovalPresenting {
    func requestLaunchApproval(_ request: LaunchApprovalRequest) async -> Bool { false }
}

public struct DenyingAccessApprovalPresenter: AccessApprovalPresenting {
    public init() {}
    public func requestLaunchApproval(_ request: LaunchApprovalRequest) async -> Bool { false }
    public func requestApproval(_ request: AccessApprovalRequest) async -> AccessApprovalDecision { .denied }
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
    func requestApproval(_ challenge: RiskChallenge, summary: String) async -> Bool
}

public struct DenyingRiskApprovalPresenter: RiskApprovalPresenting {
    public init() {}
    public func requestApproval(_ challenge: RiskChallenge, summary: String) async -> Bool { false }
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
                let label = element.label.map { ", label \(escaped($0, maximum: 512))" } ?? ""
                lines.append("Selector: \(escaped(element.role, maximum: 128))\(label)\(element.secure ? ", secure" : "")")
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
            guard let key = request.key, (1...64).contains(key.utf16.count) else {
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
    private let accessibility: AccessibilityController
    private let accessibilitySnapshots: AccessibilityFrameSnapshotStore
    private let input: SyntheticInputDriving
    private let textController: TextInteractionController
    private let focus: FocusLeaseCoordinator
    private let grants: GrantStore
    private let frames: FrameResourceStore
    private let locks: ControllerLockStore
    private let actionGate: ActionExecutionGate
    private let risks: RiskApprovalStore
    private let permissions: SystemPermissionChecking
    private let protectedPolicy: ProtectedProcessPolicy
    private let syntheticDestinationGuard: SyntheticDestinationGuard
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
    private var revokingConnections: Set<UUID> = []

    public init(
        capture: ScreenCaptureServing = ScreenCaptureService(),
        accessibility: AccessibilityController = AccessibilityController(),
        accessibilitySnapshots: AccessibilityFrameSnapshotStore = AccessibilityFrameSnapshotStore(),
        input: SyntheticInputDriving? = nil,
        focus: FocusLeaseCoordinator = FocusLeaseCoordinator(),
        grants: GrantStore = GrantStore(),
        frames: FrameResourceStore = FrameResourceStore(),
        locks: ControllerLockStore = ControllerLockStore(),
        actionGate: ActionExecutionGate = ActionExecutionGate(),
        risks: RiskApprovalStore = RiskApprovalStore(),
        permissions: SystemPermissionChecking = MacSystemPermissionChecker(),
        protectedPolicy: ProtectedProcessPolicy = ProtectedProcessPolicy(),
        syntheticDestinationGuard: SyntheticDestinationGuard? = nil,
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
        self.permissions = permissions
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
        switch method {
        case "status": return try await status(context)
        case "listDisplays": return try await listDisplays(required(params))
        case "listApps": return try await listApps(required(params))
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
        grantMetadata.removeAll()
        publishedGrantIDs.removeAll()
        lastAccessibilityRevision.removeAll()
        await locks.revokeAll()
        await indicator.hideAll()
    }

    /// Trusted local UI path for the Stop button on one grant's rail.
    public func stop(grantID: UUID) async {
        stopToken.stop(grantID: grantID)
        guard let grant = await grants.revoke(grantID: grantID) else {
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
        }
    }

    private func status(_ context: HostRequestContext) async throws -> JSONValue {
        await maintenance(now: Date())
        let snapshot = permissions.snapshot()
        let active = await grants.active(connectionID: context.connection.id)
            .filter { publishedGrantIDs.contains($0.id) }
        let summaries: [JSONValue] = active.map { grant in
            .object([
                "grantId": .string(grant.id.uuidString),
                "targetKind": .string(grantMetadata[grant.id]?.targetKind ?? "window"),
                "idleExpiresAt": .string(Self.iso(grant.expiresAt)),
            ])
        }
        return .object([
            "status": .string(snapshot.isReadyForInteractiveControl ? "ready" : "permission_required"),
            "nativeVersion": .string("0.1.0-alpha.1"),
            "platform": .string("macos"),
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

    private func listApps(_ params: JSONValue) async throws -> JSONValue {
        let apps: [JSONValue] = try await capture.inventory().applications.filter { application in
            application.processID > 1 &&
                !application.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !application.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.map { application in
            .object([
                "bundleId": .string(application.bundleIdentifier),
                "name": .string(application.name),
                "isRunning": .bool(true),
                "pid": .number(Double(application.processID)),
                "windowCount": .number(Double(application.windows.count)),
                "grantable": .bool(!application.isProtected && !application.windows.isEmpty),
            ])
        }
        return .object(["apps": .array(apps)])
    }

    private func requestAccess(_ value: JSONValue, _ context: HostRequestContext) async throws -> JSONValue {
        let request = try value.decode(RequestAccessParameters.self)
        guard (100...300_000).contains(request.timeoutMs) else {
            throw WireError(code: "ACTION_TIMEOUT", message: "Access timeout must be between 100ms and 300000ms")
        }
        let requestCancellation = stopToken.scope(connectionID: context.connection.id)
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
        let inventory = try await capture.inventory()
        var choices: [GrantChoice] = []
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
                guard protectedPolicy.evaluate(
                    bundleIdentifier: candidate.bundleIdentifier,
                    processName: candidate.name,
                    processID: 2
                ).allowed else {
                    return .object(["status": .string("denied"), "message": .string("The application is protected")])
                }
                let launchApproved = await accessPresenter.requestLaunchApproval(LaunchApprovalRequest(
                    connectionID: context.connection.id,
                    appName: candidate.name,
                    bundleIdentifier: candidate.bundleIdentifier,
                    reason: request.reason,
                    capabilities: request.capabilities
                ))
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
            let candidates = app.windows.filter { window in
                guard let hint else { return true }
                return window.title?.localizedCaseInsensitiveContains(hint) == true
            }.filter { protectedPolicy.evaluate($0).allowed }
            guard !candidates.isEmpty else {
                return .object(["status": .string("denied"), "message": .string("No matching grantable window")])
            }
            choices = candidates.map { window in
                let displayID = bestDisplay(for: window.frame, displays: inventory.displays)?.displayID ?? 0
                let displayFrame = bestDisplay(for: window.frame, displays: inventory.displays)?.frame
                    ?? Rect(CGDisplayBounds(CGMainDisplayID()))
                return GrantChoice(
                    scope: .window(window.identity),
                    frame: window.frame,
                    title: window.title ?? app.name,
                    targetMetadata: windowTargetJSON(window, app: app, displayID: displayID),
                    targetKey: "window:\(window.identity.windowID)",
                    displayFrame: displayFrame
                )
            }
        }

        var appConsentExists = false
        if !isDisplay {
            for choice in choices {
                if case .window(let window) = choice.scope,
                   await consentStore?.allows(window: window, capabilities: request.capabilities) == true {
                    appConsentExists = true
                    break
                }
            }
        }
        // Persistent app consent never selects a concrete window. The native
        // picker is shown for every new grant, including a newly created sole window.
        let decision = await accessPresenter.requestApproval(AccessApprovalRequest(
            connectionID: context.connection.id,
            reason: request.reason,
            candidates: choices,
            capabilities: request.capabilities,
            displayTarget: isDisplay,
            appConsentExists: appConsentExists
        ))
        // Native UI is intentionally asynchronous. The caller may have timed
        // out, cancelled, or disconnected while the sheet was visible; never
        // create an orphan grant or indicator after that boundary.
        try check(context)
        try requestCancellation.check()
        guard let choice = decision.selected,
              choices.contains(where: { $0.targetKey == choice.targetKey }) else {
            return .object(["status": .string("denied"), "message": .string("User denied target access")])
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
                displayTopLeftFrame: choice.displayFrame,
                harnessName: context.connection.peer.name,
                mode: request.capabilities.contains(.interact) ? "Control" : "Observe"
            ))
            try check(context)
            try requestCancellation.check()
            try pendingGrantCancellation.check()
            if persistence == .alwaysAllowApp, case .window(let window) = choice.scope {
                try await consentStore?.record(window: window, capabilities: request.capabilities)
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
        let policy = ScreenshotSizingPolicy(maxDimension: request.maxWidthPx, maxPixels: 4_000_000)
        let screenshot: ScreenshotPayload
        var accessibilityJSON: JSONValue?
        var accessibilityState: AccessibilityState?
        var target = grantMetadata[grant.id]?.target ?? .object([:])
        switch grant.scope {
        case .display(let display):
            screenshot = try await capture.captureDisplay(displayID: display.displayID, policy: policy)
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
                    maximumCharacters: request.maxAccessibilityChars
                )
                try await ensureStateRequestActive(grant, cancellation: stateCancellation, context: context)
                lastAccessibilityRevision[grant.id] = state.revision
                accessibilityState = state
            } else {
                await accessibility.close(sessionID: grant.id)
                await accessibilitySnapshots.revoke(grantID: grant.id)
                try await ensureStateRequestActive(grant, cancellation: stateCancellation, context: context)
                lastAccessibilityRevision.removeValue(forKey: grant.id)
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
        let frame = await frames.create(grantID: grant.id, connectionID: context.connection.id, transform: screenshot.transform)
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
        return .object(result)
    }

    private func action(_ raw: JSONValue, _ context: HostRequestContext) async throws -> JSONValue {
        let request = try raw.decode(HostActionRequest.self)
        try HostActionValidation.validate(request)
        let classifiedRisk = RiskClassifier.classify(
            kind: request.kind,
            intent: request.intent,
            key: request.key,
            modifiers: request.modifiers ?? []
        )
        do {
            return try await performAction(raw, request: request, context: context, riskTier: classifiedRisk)
        } catch {
            let mapped = WireErrorMapping.map(error)
            let result: AuditResult
            if mapped.code == "CANCELLED" { result = .canceled }
            else if mapped.code == "approval_required" || mapped.code.hasPrefix("APPROVAL_") || mapped.code == "ACCESS_DENIED" {
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
        _ raw: JSONValue,
        request: HostActionRequest,
        context: HostRequestContext,
        riskTier: RiskTier
    ) async throws -> JSONValue {
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
        let capability = request.usesAccessibilityAction ? HostCapability.accessibilityAction : .syntheticInput
        let grant = try await authorizeGrant(
            grantID: request.grantID,
            connectionID: context.connection.id,
            capability: capability
        )
        if request.kind == .paste,
           !(grantMetadata[grant.id]?.publicCapabilities.isSuperset(of: [.observe, .interact, .clipboardWrite]) == true) {
            throw WireError(code: "ACCESS_DENIED", message: "Paste requires clipboard_write capability")
        }
        try await revalidate(grant: grant, frame: frame)
        let digest = try actionDigest(raw)
        let elementDescriptor: AccessibilityActionDescriptor?
        if case .element(let opaque)? = request.selector,
           let revision = lastAccessibilityRevision[grant.id],
           let resolvedID = try? nodeID(opaque) {
            elementDescriptor = try? await accessibility.describeActionTarget(
                sessionID: grant.id,
                revision: revision,
                nodeID: resolvedID
            )
        } else if (request.text != nil || request.value != nil),
                  let revision = lastAccessibilityRevision[grant.id] {
            // Typed and pasted actions have no selector. Use only the unique,
            // frame-bound focused AX node to decide whether a preview is safe;
            // ambiguity fails closed to a masked length-only summary.
            elementDescriptor = try? await accessibility.describeFocusedActionTarget(
                sessionID: grant.id,
                revision: revision
            )
        } else { elementDescriptor = nil }
        let approvalSummary = RiskApprovalSummaryBuilder.summary(
            request: request,
            target: grantMetadata[grant.id]?.target ?? .object([:]),
            harnessName: context.connection.peer.name,
            element: elementDescriptor
        )
        if riskTier > .low {
            if let approvalID = request.approvalRequestID {
                guard await risks.consumeApproved(
                    approvalRequestID: approvalID,
                    connectionID: context.connection.id,
                    actionDigest: digest,
                    approvalMode: request.approvalMode
                ) else { throw WireError(code: "approval_invalid", message: "Approval is expired, mismatched or consumed") }
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
                    let approved = await riskPresenter.requestApproval(challenge, summary: approvalSummary)
                    do {
                        try check(context)
                        try actionCancellation.check()
                    } catch {
                        _ = await risks.resolve(
                            challengeID: challenge.id,
                            connectionID: context.connection.id,
                            approved: false,
                            approvalMode: .native
                        )
                        throw error
                    }
                    guard await risks.resolve(
                        challengeID: challenge.id,
                        connectionID: context.connection.id,
                        approved: approved,
                        approvalMode: .native
                    ) else {
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
        guard await actionGate.acquire(grantID: grant.id) else {
            throw WireError(code: "BUSY", message: "Another action is already running for this grant", retryable: true)
        }
        let relayedCancellation = RelayedInteractionCancellation(base: actionCancellation)
        do {
            try await withTaskCancellationHandler {
                try await execute(
                    request,
                    grant: grant,
                    frame: frame,
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
        guard await risks.resolve(
            challengeID: request.approvalRequestID,
            connectionID: context.connection.id,
            approved: request.approved,
            approvalMode: .elicitation
        ) else { throw WireError(code: "approval_not_found", message: "Approval request is missing or expired") }
        return .object([
            "approvalRequestId": .string(request.approvalRequestID.uuidString),
            "disposition": .string(request.approved ? "approved" : "denied"),
            "consumed": .bool(false),
        ])
    }

    private func execute(
        _ request: HostActionRequest,
        grant: AccessGrant,
        frame: FrameResource,
        context: HostRequestContext,
        cancellation baseCancellation: InteractionCancellationChecking
    ) async throws {
        let cancellation = DeadlineInteractionCancellation(
            base: baseCancellation,
            deadline: context.deadline
        )
        try check(context)
        try cancellation.check()
        // Approval can remain open while the target changes. Revalidate after
        // approval and immediately before dispatch, not only when the request
        // first enters the action pipeline.
        try await revalidate(grant: grant, frame: frame)
        let requiredCapability: HostCapability = request.usesAccessibilityAction
            ? .accessibilityAction : .syntheticInput
        _ = try await authorizeGrant(
            grantID: grant.id,
            connectionID: context.connection.id,
            capability: requiredCapability
        )
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
                        requireWholeTarget: false
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
                    try await accessibility.perform(
                        sessionID: grant.id,
                        revision: try currentRevision(grant.id),
                        command: .perform(nodeID: try nodeID(id), action: nil),
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
                    requireWholeTarget: false
                )
                try await Task.detached {
                    try input.drag(
                        from: globalFrom,
                        to: globalTo,
                        button: .left,
                        duration: duration,
                        cancellation: cancellation
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
                    requireWholeTarget: globalPoint == nil
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
                guard let key = request.key, let code = KeyMap.code(for: key) else { throw invalidAction("unsupported key") }
                let flags = KeyMap.flags(request.modifiers ?? [])
                try destinationGuard.validate(scope: grant.scope, globalPoints: [], requireWholeTarget: true)
                try await Task.detached {
                    try input.key(code: code, flags: flags, cancellation: cancellation)
                }.value
            case .typeText:
                guard let text = request.text else { throw invalidAction("text is required") }
                let interval = Double(request.intervalMs ?? 0) / 1_000
                for character in text.map(String.init) {
                    try cancellation.check()
                    try destinationGuard.validate(scope: grant.scope, globalPoints: [], requireWholeTarget: true)
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
                try destinationGuard.validate(scope: grant.scope, globalPoints: [], requireWholeTarget: true)
                try await Task.detached {
                    try textController.paste(text, cancellation: cancellation)
                }.value
            case .setValue:
                guard case .element(let id)? = request.selector, let value = request.value else {
                    throw invalidAction("element selector and value are required")
                }
                try await accessibility.perform(
                    sessionID: grant.id,
                    revision: try currentRevision(grant.id),
                    command: .setValue(nodeID: try nodeID(id), value: value),
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
        var object: [String: JSONValue] = [
            "kind": .string("window"),
            "app": .object([
                "bundleId": .string(app.bundleIdentifier),
                "name": .string(app.name),
                "pid": .number(Double(app.processID)),
            ]),
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

    private func actionDigest(_ raw: JSONValue) throws -> String {
        var object = raw.objectValue ?? [:]
        object.removeValue(forKey: "approvalMode")
        object.removeValue(forKey: "approvalRequestId")
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
    public static func classify(
        kind: HostActionKind,
        intent: String,
        key: String?,
        modifiers: [String]
    ) -> RiskTier {
        let normalized = intent.lowercased()
        let blocked = ["bypass security", "disable security", "steal credential", "evade approval"]
        if blocked.contains(where: normalized.contains) { return .blocked }
        let highImpact = [
            "delete", "remove", "submit", "send", "post", "publish", "message", "communicat",
            "payment", "purchase", "buy", "transfer money", "upload", "install", "uninstall",
            "permission", "privacy setting", "system setting", "credential", "password", "passcode",
            "secret", "sensitive", "medical", "prescription", "diagnosis", "transmit",
        ]
        if highImpact.contains(where: normalized.contains) { return .high }
        if kind == .pressKey,
           key?.lowercased() == "delete" || (modifiers.contains("command") && ["q", "w"].contains(key?.lowercased() ?? "")) {
            return .high
        }
        switch kind {
        case .scroll: return .low
        case .click:
            // Caller-supplied intent is audit context, never a trusted semantic
            // hit-test. Coordinate and AX presses therefore require at least a
            // medium challenge unless a future native classifier proves safety.
            return .medium
        case .drag, .pressKey, .typeText, .paste, .setValue, .selectText, .performSecondaryAction:
            return .medium
        }
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

private enum KeyMap {
    static func code(for key: String) -> UInt16? {
        let named: [String: UInt16] = [
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51,
            "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126,
            "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        ]
        if let value = named[key.lowercased()] { return value }
        let ansi: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
            "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
            "n": 45, "m": 46, ".": 47, "`": 50,
        ]
        guard key.count == 1, let character = key.lowercased().first else { return nil }
        return ansi[character]
    }

    static func flags(_ modifiers: [String]) -> UInt64 {
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
