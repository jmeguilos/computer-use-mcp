import AppKit
import ApplicationServices
import Foundation

public struct AccessibilityNodeSnapshot: Codable, Equatable, Sendable {
    public let id: Int
    public let parentID: Int?
    public let depth: Int
    public let role: String
    public let subrole: String?
    public let title: String?
    public let label: String?
    public let value: String?
    public let frame: Rect?
    public let isEnabled: Bool?
    public let isFocused: Bool
    public let isSelected: Bool?
    public let secure: Bool
    public let actions: [String]
}

/// Pure projection helpers used both by the live AX walker and by tests. Secure
/// classification must consider the subrole: macOS commonly reports a generic
/// AXTextField role with AXSecureTextField as its subrole.
public enum AccessibilityProjection {
    public static func isDirectSecureTextField(role: String, subrole: String?) -> Bool {
        role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    public static func isProtectedContent(role: String, subrole: String?) -> Bool {
        role == "AXProtectedContent" || subrole == "AXProtectedContent"
    }

    public static func isSecure(role: String, subrole: String?, ancestorSecure: Bool = false) -> Bool {
        ancestorSecure ||
            isDirectSecureTextField(role: role, subrole: subrole) ||
            isProtectedContent(role: role, subrole: subrole)
    }

    public static func redactedStrings(
        role: String,
        subrole: String?,
        title: String?,
        label: String?,
        value: String?
    ) -> (title: String?, label: String?, value: String?, secure: Bool) {
        let secure = isSecure(role: role, subrole: subrole)
        return secure ? (nil, nil, nil, true) : (title, label, value, false)
    }

    public static func boundedCharacterCount(_ values: [String]) -> Int {
        values.reduce(0) { $0 + $1.utf16.count }
    }
}

/// A secure field is write-only from the host's perspective. Only a direct
/// secure text control can accept an exact, already-approved value write.
/// Protected content, secure descendants, and ambiguous ancestry stay denied.
public enum AccessibilitySecureElementPolicy {
    public static func allowsValueWrite(
        role: String,
        subrole: String?,
        secureAncestorOrAmbiguity: Bool,
        authorization: AccessibilityValueWriteAuthorization
    ) -> Bool {
        guard !secureAncestorOrAmbiguity else { return false }
        guard !AccessibilityProjection.isProtectedContent(role: role, subrole: subrole) else {
            return false
        }
        let directSecure = AccessibilityProjection.isDirectSecureTextField(
            role: role,
            subrole: subrole
        )
        switch authorization {
        case .ordinary:
            return !directSecure
        case .approvedDirectSecure:
            return directSecure
        }
    }
}

public struct AccessibilityState: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let revision: UInt64
    public let window: WindowDescriptor
    public let nodes: [AccessibilityNodeSnapshot]
    public let truncated: Bool
}

/// Retains only the small, frame-bound history needed to answer an incremental
/// state request. Element identifiers remain authority-bound to their frame;
/// this cache is projection data only and never extends a frame's action
/// lifetime.
public actor AccessibilityFrameSnapshotStore {
    private struct Entry: Sendable {
        let frameID: UUID
        let state: AccessibilityState
    }

    private var entriesByGrant: [UUID: [Entry]] = [:]
    private let maximumEntriesPerGrant: Int

    public init(maximumEntriesPerGrant: Int = 2) {
        self.maximumEntriesPerGrant = max(1, maximumEntriesPerGrant)
    }

    public func state(grantID: UUID, frameID: UUID) -> AccessibilityState? {
        entriesByGrant[grantID]?.first(where: { $0.frameID == frameID })?.state
    }

    public func record(grantID: UUID, frameID: UUID, state: AccessibilityState) {
        var entries = entriesByGrant[grantID, default: []]
        entries.removeAll { $0.frameID == frameID }
        entries.append(Entry(frameID: frameID, state: state))
        if entries.count > maximumEntriesPerGrant {
            entries.removeFirst(entries.count - maximumEntriesPerGrant)
        }
        entriesByGrant[grantID] = entries
    }

    public func revoke(grantID: UUID) {
        entriesByGrant.removeValue(forKey: grantID)
    }

    public func revoke(grantIDs: [UUID]) {
        for grantID in grantIDs { entriesByGrant.removeValue(forKey: grantID) }
    }

    public func revokeAll() {
        entriesByGrant.removeAll()
    }

    public func retainedFrameIDs(grantID: UUID) -> [UUID] {
        entriesByGrant[grantID, default: []].map(\.frameID)
    }
}

public enum AccessibilityValueWriteAuthorization: Equatable, Sendable {
    case ordinary
    case approvedDirectSecure
}

public enum AccessibilityCommand: Equatable, Sendable {
    case perform(nodeID: Int, action: String?)
    case setValue(
        nodeID: Int,
        value: String,
        authorization: AccessibilityValueWriteAuthorization
    )
    case focus(nodeID: Int)
}

public struct AccessibilityActionDescriptor: Equatable, Sendable {
    public let role: String
    public let label: String?
    public let secure: Bool
    public let actions: [String]
    public let frame: Rect?
    public let subrole: String?
    public let title: String?
    public let identifier: String?
    public let help: String?
    public let placeholder: String?
    public let semanticContext: [String]

    public init(
        role: String,
        label: String?,
        secure: Bool,
        actions: [String],
        frame: Rect?,
        subrole: String? = nil,
        title: String? = nil,
        identifier: String? = nil,
        help: String? = nil,
        placeholder: String? = nil,
        semanticContext: [String] = []
    ) {
        self.role = role
        self.label = label
        self.secure = secure
        self.actions = actions
        self.frame = frame
        self.subrole = subrole
        self.title = title
        self.identifier = identifier
        self.help = help
        self.placeholder = placeholder
        self.semanticContext = semanticContext
    }

    /// Human-facing AX metadata only. Values and selected text are deliberately
    /// absent so semantic classification never turns field contents into
    /// approval or audit metadata.
    public var semanticMetadata: [String] {
        ([role, subrole, title, label, identifier, help, placeholder]
            .compactMap { value in
                guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else { return nil }
                return value
            }) + semanticContext
    }

    public var semanticLabel: String? {
        [label, title, placeholder, help, identifier]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    public func hasSameControlSemantics(as other: AccessibilityActionDescriptor) -> Bool {
        role == other.role
            && subrole == other.subrole
            && title == other.title
            && label == other.label
            && identifier == other.identifier
            && help == other.help
            && placeholder == other.placeholder
            && semanticContext == other.semanticContext
            && secure == other.secure
            && actions.sorted() == other.actions.sorted()
    }
}

public enum AccessibilityError: String, Error, Codable, Equatable, Sendable {
    case permissionDenied
    case windowNotFound
    case windowMappingAmbiguous
    case staleRevision
    case sessionNotFound
    case elementNotFound
    case actionUnsupported
    case attributeNotSettable
    case operationFailed
    case focusMismatch
    case secureElement
    case textNotFound
    case textAmbiguous
}

private final class AXElementBox: @unchecked Sendable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
}

/// Opaque, in-memory identity for one concrete AX window object. Retaining the
/// object lets the host distinguish a same-process close/recreate cycle even if
/// macOS later reuses the same public CGWindowID and metadata.
public final class AccessibilityWindowBinding: @unchecked Sendable {
    fileprivate let element: AXUIElement
    fileprivate init(element: AXUIElement) { self.element = element }

    /// Test doubles may retain this inert token. The production controller
    /// always replaces it with a concrete, mapped AX window and therefore
    /// cannot treat this helper as authority.
    static func fixtureToken() -> AccessibilityWindowBinding {
        AccessibilityWindowBinding(element: AXUIElementCreateSystemWide())
    }
}

public protocol AccessibilityServing: Actor {
    func state(
        sessionID: UUID,
        window: WindowDescriptor,
        maximumNodes: Int,
        maximumDepth: Int,
        maximumCharacters: Int
    ) throws -> AccessibilityState
    func perform(
        sessionID: UUID,
        revision: UInt64,
        command: AccessibilityCommand,
        cancellation: any InteractionCancellationChecking
    ) throws
    func createWindowBinding(window: WindowDescriptor) throws -> AccessibilityWindowBinding
    func validateWindowBinding(_ binding: AccessibilityWindowBinding, window: WindowDescriptor) throws
    func validateWindowBinding(sessionID: UUID, window: WindowDescriptor) throws
    func openWindowSession(
        sessionID: UUID,
        binding: AccessibilityWindowBinding,
        window: WindowDescriptor
    ) throws
    func refreshWindowBinding(sessionID: UUID, window: WindowDescriptor) throws -> UInt64
    func validateFocusedWindow(sessionID: UUID, revision: UInt64) throws
    func describeActionTarget(
        sessionID: UUID,
        revision: UInt64,
        nodeID: Int
    ) throws -> AccessibilityActionDescriptor
    func describeFocusedActionTarget(
        sessionID: UUID,
        revision: UInt64
    ) throws -> AccessibilityActionDescriptor
    func raise(
        window: WindowDescriptor,
        cancellation: any InteractionCancellationChecking
    ) async throws
    func selectText(
        sessionID: UUID,
        revision: UInt64,
        nodeID: Int,
        text: String,
        prefix: String?,
        suffix: String?,
        selectionType: String,
        cancellation: any InteractionCancellationChecking
    ) throws
    func close(sessionID: UUID)
}

private struct AccessibilitySession: @unchecked Sendable {
    let window: WindowDescriptor
    let windowElement: AXElementBox
    var revision: UInt64
    var elements: [Int: AXElementBox]
}

public actor AccessibilityController: AccessibilityServing {
    private var sessions: [UUID: AccessibilitySession] = [:]
    private let permissionChecker: SystemPermissionChecking

    public init(permissionChecker: SystemPermissionChecking = MacSystemPermissionChecker()) {
        self.permissionChecker = permissionChecker
    }

    public func state(
        sessionID: UUID,
        window: WindowDescriptor,
        maximumNodes: Int = 1_200,
        maximumDepth: Int = 64,
        maximumCharacters: Int = 256_000
    ) throws -> AccessibilityState {
        guard permissionChecker.snapshot().accessibility == .granted else {
            throw AccessibilityError.permissionDenied
        }
        let mappedWindowElement = try mapWindow(window)
        let priorSession = sessions[sessionID]
        if let priorSession {
            guard priorSession.window.identity == window.identity,
                  CFEqual(priorSession.windowElement.element, mappedWindowElement) else {
                throw AccessibilityError.windowNotFound
            }
        }
        let windowElement = priorSession?.windowElement.element ?? mappedWindowElement
        let expectedApplication = AXUIElementCreateApplication(window.identity.processID)
        var nodes: [AccessibilityNodeSnapshot] = []
        var elements: [Int: AXElementBox] = [:]
        var truncated = false
        var nextID = 0
        var emittedCharacters = 0

        func visit(_ element: AXUIElement, parentID: Int?, depth: Int) {
            guard !truncated else { return }
            guard nodes.count < maximumNodes, depth <= maximumDepth,
                  emittedCharacters < maximumCharacters else {
                truncated = true
                return
            }
            let id = nextID
            nextID += 1
            let role = AXHelpers.stringAttribute(element, kAXRoleAttribute) ?? "AXUnknown"
            let subrole = AXHelpers.stringAttribute(element, kAXSubroleAttribute)
            // Determine protection before querying any content-bearing AX
            // attribute. Secure fields and descendants are write-only: their
            // title, description, value, and actions are never read.
            let secure = AXHelpers.isSecure(
                element,
                expectedApplication: expectedApplication
            )
            let strings: (title: String?, label: String?, value: String?) = secure
                ? (title: nil, label: nil, value: nil)
                : (
                    title: AXHelpers.limited(AXHelpers.stringAttribute(element, kAXTitleAttribute)),
                    label: AXHelpers.limited(AXHelpers.stringAttribute(element, kAXDescriptionAttribute)),
                    value: AXHelpers.limited(AXHelpers.displayValue(element))
                )
            let position = AXHelpers.pointAttribute(element, kAXPositionAttribute)
            let size = AXHelpers.sizeAttribute(element, kAXSizeAttribute)
            let frame: Rect?
            if let position, let size, size.width >= 0, size.height >= 0 {
                frame = Rect(CGRect(origin: position, size: size))
            } else {
                frame = nil
            }
            let snapshot = AccessibilityNodeSnapshot(
                id: id,
                parentID: parentID,
                depth: depth,
                role: role,
                subrole: subrole,
                title: strings.title,
                label: strings.label,
                value: strings.value,
                frame: frame,
                isEnabled: AXHelpers.boolAttribute(element, kAXEnabledAttribute),
                isFocused: AXHelpers.boolAttribute(element, kAXFocusedAttribute) ?? false,
                isSelected: AXHelpers.boolAttribute(element, kAXSelectedAttribute),
                secure: secure,
                actions: secure ? [] : AXHelpers.actionNames(element)
            )
            emittedCharacters += AccessibilityProjection.boundedCharacterCount(
                [role, snapshot.subrole, snapshot.title, snapshot.label, snapshot.value]
                    .compactMap { $0 } + snapshot.actions
            )
            if emittedCharacters > maximumCharacters {
                truncated = true
                return
            }
            nodes.append(snapshot)
            elements[id] = AXElementBox(element)
            for child in AXHelpers.elementArrayAttribute(element, kAXChildrenAttribute) {
                visit(child, parentID: id, depth: depth + 1)
                if truncated { break }
            }
        }

        visit(windowElement, parentID: nil, depth: 0)
        let revision = (priorSession?.revision ?? 0) + 1
        sessions[sessionID] = AccessibilitySession(
            window: window,
            windowElement: AXElementBox(windowElement),
            revision: revision,
            elements: elements
        )
        return AccessibilityState(
            sessionID: sessionID,
            revision: revision,
            window: window,
            nodes: nodes,
            truncated: truncated
        )
    }

    public func perform(
        sessionID: UUID,
        revision: UInt64,
        command: AccessibilityCommand,
        cancellation: any InteractionCancellationChecking = NeverCanceled()
    ) throws {
        try cancellation.check()
        guard let session = sessions[sessionID] else { throw AccessibilityError.sessionNotFound }
        guard session.revision == revision else { throw AccessibilityError.staleRevision }
        let expectedApplication = AXUIElementCreateApplication(session.window.identity.processID)

        switch command {
        case .perform(let nodeID, let requestedAction):
            guard let element = session.elements[nodeID]?.element else { throw AccessibilityError.elementNotFound }
            guard !AXHelpers.isSecure(element, expectedApplication: expectedApplication) else {
                throw AccessibilityError.secureElement
            }
            let action = requestedAction ?? (kAXPressAction as String)
            guard AXHelpers.actionNames(element).contains(action) else { throw AccessibilityError.actionUnsupported }
            try cancellation.check()
            guard AXUIElementPerformAction(element, action as CFString) == .success else {
                throw AccessibilityError.operationFailed
            }
        case .setValue(let nodeID, let value, let authorization):
            guard let element = session.elements[nodeID]?.element else { throw AccessibilityError.elementNotFound }
            let role = AXHelpers.stringAttribute(element, kAXRoleAttribute) ?? "AXUnknown"
            let subrole = AXHelpers.stringAttribute(element, kAXSubroleAttribute)
            guard AccessibilitySecureElementPolicy.allowsValueWrite(
                role: role,
                subrole: subrole,
                secureAncestorOrAmbiguity: AXHelpers.hasSecureAncestorOrAmbiguity(
                    element,
                    expectedApplication: expectedApplication
                ),
                authorization: authorization
            ) else { throw AccessibilityError.secureElement }
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
                  settable.boolValue else {
                throw AccessibilityError.attributeNotSettable
            }
            try cancellation.check()
            guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString) == .success else {
                throw AccessibilityError.operationFailed
            }
        case .focus(let nodeID):
            guard let element = session.elements[nodeID]?.element else { throw AccessibilityError.elementNotFound }
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &settable) == .success,
                  settable.boolValue else {
                throw AccessibilityError.attributeNotSettable
            }
            try cancellation.check()
            guard AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
                throw AccessibilityError.operationFailed
            }
        }
    }

    public func prepareForSyntheticInput(sessionID: UUID, revision: UInt64) throws {
        guard let session = sessions[sessionID] else { throw AccessibilityError.sessionNotFound }
        guard session.revision == revision else { throw AccessibilityError.staleRevision }
        let application = AXUIElementCreateApplication(session.window.identity.processID)
        _ = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        guard AXUIElementPerformAction(session.windowElement.element, kAXRaiseAction as CFString) == .success else {
            throw AccessibilityError.operationFailed
        }
    }

    public func createWindowBinding(window: WindowDescriptor) throws -> AccessibilityWindowBinding {
        guard permissionChecker.snapshot().accessibility == .granted else {
            throw AccessibilityError.permissionDenied
        }
        return AccessibilityWindowBinding(element: try mapWindow(window))
    }

    public func validateWindowBinding(
        _ binding: AccessibilityWindowBinding,
        window: WindowDescriptor
    ) throws {
        guard permissionChecker.snapshot().accessibility == .granted else {
            throw AccessibilityError.permissionDenied
        }
        let current = try mapWindow(window)
        guard CFEqual(binding.element, current) else { throw AccessibilityError.windowNotFound }
    }

    /// Revalidates the concrete AX window retained for a live grant. Public
    /// window metadata is not sufficient here because WindowServer may reuse a
    /// numeric window ID after a close/recreate cycle.
    public func validateWindowBinding(
        sessionID: UUID,
        window: WindowDescriptor
    ) throws {
        guard permissionChecker.snapshot().accessibility == .granted else {
            throw AccessibilityError.permissionDenied
        }
        guard let session = sessions[sessionID] else { throw AccessibilityError.sessionNotFound }
        guard session.window.identity == window.identity else { throw AccessibilityError.windowNotFound }
        let current = try mapWindow(window)
        guard CFEqual(session.windowElement.element, current) else {
            throw AccessibilityError.windowNotFound
        }
    }

    public func openWindowSession(
        sessionID: UUID,
        binding: AccessibilityWindowBinding,
        window: WindowDescriptor
    ) throws {
        try validateWindowBinding(binding, window: window)
        sessions[sessionID] = AccessibilitySession(
            window: window,
            windowElement: AXElementBox(binding.element),
            revision: 0,
            elements: [:]
        )
    }

    /// Refreshes the frame-bound window identity without exposing an AX tree.
    /// Previous element IDs are discarded so an accessibility-free state call
    /// cannot leave older nodes actionable.
    public func refreshWindowBinding(
        sessionID: UUID,
        window: WindowDescriptor
    ) throws -> UInt64 {
        guard permissionChecker.snapshot().accessibility == .granted else {
            throw AccessibilityError.permissionDenied
        }
        let current = try mapWindow(window)
        if let prior = sessions[sessionID] {
            guard prior.window.identity == window.identity,
                  CFEqual(prior.windowElement.element, current) else {
                throw AccessibilityError.windowNotFound
            }
            let revision = prior.revision + 1
            sessions[sessionID] = AccessibilitySession(
                window: window,
                windowElement: prior.windowElement,
                revision: revision,
                elements: [:]
            )
            return revision
        }
        sessions[sessionID] = AccessibilitySession(
            window: window,
            windowElement: AXElementBox(current),
            revision: 1,
            elements: [:]
        )
        return 1
    }

    public func validateFocusedWindow(sessionID: UUID, revision: UInt64) throws {
        guard let session = sessions[sessionID] else { throw AccessibilityError.sessionNotFound }
        guard session.revision == revision else { throw AccessibilityError.staleRevision }
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier == session.window.identity.processID,
              frontmost.bundleIdentifier == session.window.identity.bundleIdentifier else {
            throw AccessibilityError.focusMismatch
        }
        let application = AXUIElementCreateApplication(session.window.identity.processID)
        guard let focused = AXHelpers.copyAttribute(application, kAXFocusedWindowAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID(),
              CFEqual(focused, session.windowElement.element) else {
            throw AccessibilityError.focusMismatch
        }
    }

    public func describeActionTarget(
        sessionID: UUID,
        revision: UInt64,
        nodeID: Int
    ) throws -> AccessibilityActionDescriptor {
        guard let session = sessions[sessionID] else { throw AccessibilityError.sessionNotFound }
        guard session.revision == revision else { throw AccessibilityError.staleRevision }
        guard let element = session.elements[nodeID]?.element else { throw AccessibilityError.elementNotFound }
        return Self.actionDescriptor(
            element,
            expectedApplication: AXUIElementCreateApplication(session.window.identity.processID)
        )
    }

    public func describeFocusedActionTarget(
        sessionID: UUID,
        revision: UInt64
    ) throws -> AccessibilityActionDescriptor {
        guard let session = sessions[sessionID] else { throw AccessibilityError.sessionNotFound }
        guard session.revision == revision else { throw AccessibilityError.staleRevision }
        let focused = session.elements
            .sorted { $0.key < $1.key }
            .compactMap { AXHelpers.boolAttribute($0.value.element, kAXFocusedAttribute) == true ? $0.value.element : nil }
        guard focused.count == 1, let element = focused.first else {
            throw AccessibilityError.elementNotFound
        }
        return Self.actionDescriptor(
            element,
            expectedApplication: AXUIElementCreateApplication(session.window.identity.processID)
        )
    }

    private static func actionDescriptor(
        _ element: AXUIElement,
        expectedApplication: AXUIElement
    ) -> AccessibilityActionDescriptor {
        let role = AXHelpers.stringAttribute(element, kAXRoleAttribute) ?? "AXUnknown"
        let secure = AXHelpers.isSecure(element, expectedApplication: expectedApplication)
        return AccessibilityActionDescriptor(
            role: role,
            label: secure ? nil : AXHelpers.limited(AXHelpers.stringAttribute(element, kAXDescriptionAttribute)),
            secure: secure,
            actions: secure ? [] : AXHelpers.actionNames(element),
            frame: {
                guard let position = AXHelpers.pointAttribute(element, kAXPositionAttribute),
                      let size = AXHelpers.sizeAttribute(element, kAXSizeAttribute) else { return nil }
                return Rect(CGRect(origin: position, size: size))
            }(),
            subrole: AXHelpers.stringAttribute(element, kAXSubroleAttribute),
            title: secure ? nil : AXHelpers.limited(AXHelpers.stringAttribute(element, kAXTitleAttribute)),
            identifier: secure ? nil : AXHelpers.limited(AXHelpers.stringAttribute(element, kAXIdentifierAttribute)),
            help: secure ? nil : AXHelpers.limited(AXHelpers.stringAttribute(element, kAXHelpAttribute)),
            placeholder: secure ? nil : AXHelpers.limited(AXHelpers.stringAttribute(element, kAXPlaceholderValueAttribute)),
            semanticContext: secure ? [] : AXHelpers.semanticAncestry(
                element,
                expectedApplication: expectedApplication
            )
        )
    }

    public func raise(
        window: WindowDescriptor,
        cancellation: any InteractionCancellationChecking = NeverCanceled()
    ) async throws {
        try cancellation.check()
        guard permissionChecker.snapshot().accessibility == .granted else {
            throw AccessibilityError.permissionDenied
        }
        let windowElement = try mapWindow(window)
        let application = AXUIElementCreateApplication(window.identity.processID)
        try cancellation.check()
        guard AXUIElementSetAttributeValue(
            application,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        ) == .success,
        AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString) == .success else {
            throw AccessibilityError.operationFailed
        }
        // AXRaise is delivered asynchronously by some applications. Do not
        // post keyboard input until the exact mapped AX window reports focused.
        for _ in 0..<10 {
            try cancellation.check()
            if let focused = AXHelpers.copyAttribute(application, kAXFocusedWindowAttribute),
               CFGetTypeID(focused) == AXUIElementGetTypeID(),
               CFEqual(focused, windowElement) {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw AccessibilityError.focusMismatch
    }

    public func selectText(
        sessionID: UUID,
        revision: UInt64,
        nodeID: Int,
        text: String,
        prefix: String?,
        suffix: String?,
        selectionType: String,
        cancellation: any InteractionCancellationChecking = NeverCanceled()
    ) throws {
        try cancellation.check()
        guard let session = sessions[sessionID] else { throw AccessibilityError.sessionNotFound }
        guard session.revision == revision else { throw AccessibilityError.staleRevision }
        guard let element = session.elements[nodeID]?.element else { throw AccessibilityError.elementNotFound }
        guard !AXHelpers.isSecure(
            element,
            expectedApplication: AXUIElementCreateApplication(session.window.identity.processID)
        ) else {
            throw AccessibilityError.secureElement
        }
        guard let fullValue = AXHelpers.stringAttribute(element, kAXValueAttribute) else {
            throw AccessibilityError.textNotFound
        }
        var candidates: [Range<String.Index>] = []
        var searchStart = fullValue.startIndex
        while searchStart <= fullValue.endIndex,
              let range = fullValue.range(of: text, range: searchStart..<fullValue.endIndex) {
            let beforeMatches = prefix.map { prefix in
                let before = fullValue[..<range.lowerBound]
                return before.hasSuffix(prefix)
            } ?? true
            let afterMatches = suffix.map { suffix in
                let after = fullValue[range.upperBound...]
                return after.hasPrefix(suffix)
            } ?? true
            if beforeMatches && afterMatches { candidates.append(range) }
            if range.upperBound == fullValue.endIndex { break }
            searchStart = fullValue.index(after: range.lowerBound)
        }
        guard !candidates.isEmpty else { throw AccessibilityError.textNotFound }
        guard candidates.count == 1 else { throw AccessibilityError.textAmbiguous }
        let match = candidates[0]
        let location = fullValue.utf16.distance(from: fullValue.utf16.startIndex, to: match.lowerBound.samePosition(in: fullValue.utf16)!)
        let length = fullValue.utf16.distance(
            from: match.lowerBound.samePosition(in: fullValue.utf16)!,
            to: match.upperBound.samePosition(in: fullValue.utf16)!
        )
        let selected: CFRange
        switch selectionType {
        case "cursor_before": selected = CFRange(location: location, length: 0)
        case "cursor_after": selected = CFRange(location: location + length, length: 0)
        case "text": selected = CFRange(location: location, length: length)
        default: throw AccessibilityError.operationFailed
        }
        var mutable = selected
        guard let rangeValue = AXValueCreate(.cfRange, &mutable) else { throw AccessibilityError.operationFailed }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &settable
        ) == .success, settable.boolValue else {
            throw AccessibilityError.attributeNotSettable
        }
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try cancellation.check()
        guard AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        ) == .success else { throw AccessibilityError.operationFailed }
    }

    public func close(sessionID: UUID) {
        sessions.removeValue(forKey: sessionID)
    }

    private func mapWindow(_ descriptor: WindowDescriptor) throws -> AXUIElement {
        let application = AXUIElementCreateApplication(descriptor.identity.processID)
        let windows = AXHelpers.elementArrayAttribute(application, kAXWindowsAttribute)
        let expected = descriptor.frame.cgRect
        let candidates = windows.filter { element in
            guard let position = AXHelpers.pointAttribute(element, kAXPositionAttribute),
                  let size = AXHelpers.sizeAttribute(element, kAXSizeAttribute) else { return false }
            let candidate = CGRect(origin: position, size: size)
            let geometryMatches = abs(candidate.minX - expected.minX) <= 2 &&
                abs(candidate.minY - expected.minY) <= 2 &&
                abs(candidate.width - expected.width) <= 2 &&
                abs(candidate.height - expected.height) <= 2
            guard geometryMatches else { return false }
            guard let expectedTitle = descriptor.title, !expectedTitle.isEmpty else { return true }
            return AXHelpers.stringAttribute(element, kAXTitleAttribute) == expectedTitle
        }
        guard !candidates.isEmpty else { throw AccessibilityError.windowNotFound }
        guard candidates.count == 1 else { throw AccessibilityError.windowMappingAmbiguous }
        return candidates[0]
    }
}

enum AXHelpers {
    static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }

    static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        copyAttribute(element, attribute) as? Bool
    }

    static func elementArrayAttribute(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        copyAttribute(element, attribute) as? [AXUIElement] ?? []
    }

    static func pointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copyAttribute(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func sizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copyAttribute(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    static func actionNames(_ element: AXUIElement) -> [String] {
        var actions: CFArray?
        guard AXUIElementCopyActionNames(element, &actions) == .success else { return [] }
        return (actions as? [String] ?? []).sorted()
    }

    static func isSecure(
        _ element: AXUIElement,
        expectedApplication: AXUIElement
    ) -> Bool {
        let role = stringAttribute(element, kAXRoleAttribute) ?? "AXUnknown"
        let subrole = stringAttribute(element, kAXSubroleAttribute)
        if AccessibilityProjection.isSecure(role: role, subrole: subrole) { return true }
        return hasSecureAncestorOrAmbiguity(
            element,
            expectedApplication: expectedApplication
        )
    }

    /// Returns true for a secure ancestor and for ancestry that cannot be
    /// resolved within the strict depth bound. The latter is deliberately
    /// treated as ambiguous and therefore protected.
    static func hasSecureAncestorOrAmbiguity(
        _ element: AXUIElement,
        expectedApplication: AXUIElement
    ) -> Bool {
        var current = element
        var visited: [AXUIElement] = []
        for _ in 0..<16 {
            // Only the concrete application element for the granted PID is an
            // accepted root. AX role strings are target-controlled metadata
            // and cannot prove that a parent chain reached that root.
            if CFEqual(current, expectedApplication) {
                return false
            }
            guard let parentValue = copyAttribute(current, kAXParentAttribute),
                  CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { return true }
            let parent = unsafeBitCast(parentValue, to: AXUIElement.self)
            guard !CFEqual(current, parent),
                  !visited.contains(where: { CFEqual($0, parent) }) else { return true }
            if AccessibilityProjection.isSecure(
                role: stringAttribute(parent, kAXRoleAttribute) ?? "AXUnknown",
                subrole: stringAttribute(parent, kAXSubroleAttribute)
            ) { return true }
            visited.append(current)
            current = parent
        }
        // A pathological ancestry cycle or excessive depth is ambiguous; fail
        // closed rather than mutating potentially protected data.
        return true
    }

    /// Collects bounded, non-value ancestor metadata so generic controls such
    /// as "Confirm" can inherit semantic context from a containing payment,
    /// upload or medical sheet. AXValue and selection attributes are never
    /// queried here.
    static func semanticAncestry(
        _ element: AXUIElement,
        expectedApplication: AXUIElement,
        maximumDepth: Int = 8,
        maximumCharacters: Int = 4_096
    ) -> [String] {
        guard !isSecure(element, expectedApplication: expectedApplication) else { return [] }
        var context: [String] = []
        var retainedCharacters = 0
        var current: AXUIElement? = {
            guard let parent = copyAttribute(element, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(parent, to: AXUIElement.self)
        }()
        for _ in 0..<maximumDepth {
            guard let candidate = current else { break }
            let role = stringAttribute(candidate, kAXRoleAttribute) ?? "AXUnknown"
            let metadata = [
                stringAttribute(candidate, kAXTitleAttribute),
                stringAttribute(candidate, kAXDescriptionAttribute),
                stringAttribute(candidate, kAXIdentifierAttribute),
                stringAttribute(candidate, kAXHelpAttribute),
                stringAttribute(candidate, kAXPlaceholderValueAttribute),
            ]
                .compactMap { limited($0, maximum: 512)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !metadata.isEmpty {
                let entry = "\(role): \(metadata.joined(separator: " "))"
                let remaining = maximumCharacters - retainedCharacters
                guard remaining > 0, let bounded = limited(entry, maximum: remaining) else { break }
                if !context.contains(bounded) {
                    context.append(bounded)
                    retainedCharacters += bounded.utf16.count
                }
            }
            guard let parent = copyAttribute(candidate, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = unsafeBitCast(parent, to: AXUIElement.self)
        }
        return context
    }

    static func displayValue(_ element: AXUIElement) -> String? {
        guard let value = copyAttribute(element, kAXValueAttribute) else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let array = value as? [Any] { return array.map(String.init(describing:)).joined(separator: ", ") }
        return nil
    }

    static func limited(_ value: String?, maximum: Int = 1_024) -> String? {
        guard let value else { return nil }
        guard value.utf16.count > maximum else { return value }
        var result = ""
        result.reserveCapacity(maximum)
        for character in value {
            if result.utf16.count + String(character).utf16.count > maximum { break }
            result.append(character)
        }
        return result
    }
}
