import AppKit
import ApplicationServices
import Foundation

public enum InteractionSafetyError: String, Error, Codable, Equatable, Sendable {
    case focusCaptureFailed
    case focusActivationFailed
    case focusRestoreFailed
    case clipboardWriteFailed
    case clipboardChangedExternally
    case clipboardRestoreFailed

    public var wireCode: String {
        switch self {
        case .focusCaptureFailed, .focusActivationFailed, .focusRestoreFailed: return "FOCUS_FAILED"
        default: return rawValue
        }
    }
}

public struct FocusSnapshot: @unchecked Sendable {
    public let processID: Int32
    fileprivate let focusedWindow: AXUIElement?

    public init(processID: Int32, focusedWindow: AXUIElement? = nil) {
        self.processID = processID
        self.focusedWindow = focusedWindow
    }
}

public protocol ApplicationFocusManaging: Sendable {
    func capture() throws -> FocusSnapshot
    func activate(processID: Int32) -> Bool
    func restore(_ snapshot: FocusSnapshot) -> Bool
}

public struct MacApplicationFocusManager: ApplicationFocusManaging {
    public init() {}

    public func capture() throws -> FocusSnapshot {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            throw InteractionSafetyError.focusCaptureFailed
        }
        let axApplication = AXUIElementCreateApplication(application.processIdentifier)
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            axApplication,
            kAXFocusedWindowAttribute as CFString,
            &focused
        )
        let window: AXUIElement?
        if result == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            window = unsafeBitCast(focused, to: AXUIElement.self)
        } else {
            window = nil
        }
        return FocusSnapshot(processID: application.processIdentifier, focusedWindow: window)
    }

    public func activate(processID: Int32) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: processID), !application.isTerminated else {
            return false
        }
        return application.activate(options: [])
    }

    public func restore(_ snapshot: FocusSnapshot) -> Bool {
        guard activate(processID: snapshot.processID) else { return false }
        if let focusedWindow = snapshot.focusedWindow {
            return AXUIElementPerformAction(focusedWindow, kAXRaiseAction as CFString) == .success
        }
        return true
    }
}

public struct FocusLeaseCoordinator: Sendable {
    private let manager: ApplicationFocusManaging

    public init(manager: ApplicationFocusManaging = MacApplicationFocusManager()) {
        self.manager = manager
    }

    public func withFocus<T>(processID: Int32, operation: () throws -> T) throws -> T {
        let snapshot = try manager.capture()
        guard manager.activate(processID: processID) else { throw InteractionSafetyError.focusActivationFailed }
        do {
            let result = try operation()
            guard manager.restore(snapshot) else { throw InteractionSafetyError.focusRestoreFailed }
            return result
        } catch {
            guard manager.restore(snapshot) else { throw InteractionSafetyError.focusRestoreFailed }
            throw error
        }
    }

    public func acquire(processID: Int32) throws -> FocusLease {
        let snapshot = try manager.capture()
        guard manager.activate(processID: processID) else { throw InteractionSafetyError.focusActivationFailed }
        return FocusLease(snapshot: snapshot, manager: manager)
    }
}

public final class FocusLease: @unchecked Sendable {
    private let snapshot: FocusSnapshot
    private let manager: ApplicationFocusManaging
    private let lock = NSLock()
    private var restored = false

    fileprivate init(snapshot: FocusSnapshot, manager: ApplicationFocusManaging) {
        self.snapshot = snapshot
        self.manager = manager
    }

    public func restore() throws {
        let shouldRestore = lock.withLock { () -> Bool in
            guard !restored else { return false }
            restored = true
            return true
        }
        guard !shouldRestore || manager.restore(snapshot) else {
            throw InteractionSafetyError.focusRestoreFailed
        }
    }
}

public struct PasteboardItemSnapshot: Equatable, Sendable {
    public let values: [String: Data]
    public init(values: [String: Data]) { self.values = values }
}

public struct PasteboardSnapshot: Equatable, Sendable {
    public let items: [PasteboardItemSnapshot]
    public let capturedChangeCount: Int
    public init(items: [PasteboardItemSnapshot], capturedChangeCount: Int) {
        self.items = items
        self.capturedChangeCount = capturedChangeCount
    }
}

public enum PasteboardTextStagingResult: Equatable, Sendable {
    case staged(ownedChangeCount: Int)
    case failedAfterMutation(ownedChangeCount: Int)
}

public protocol PasteboardAccessing: AnyObject, Sendable {
    var changeCount: Int { get }
    func snapshot() -> PasteboardSnapshot
    func replaceWithText(_ text: String) -> PasteboardTextStagingResult
    func restore(_ snapshot: PasteboardSnapshot, ifOwnedChangeCount: Int) -> Bool
}

public final class GeneralPasteboardAdapter: PasteboardAccessing, @unchecked Sendable {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }
    public var changeCount: Int { pasteboard.changeCount }

    public func snapshot() -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            var values: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { values[type.rawValue] = data }
            }
            return PasteboardItemSnapshot(values: values)
        }
        return PasteboardSnapshot(items: items, capturedChangeCount: pasteboard.changeCount)
    }

    public func replaceWithText(_ text: String) -> PasteboardTextStagingResult {
        let clearedChangeCount = pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            return .failedAfterMutation(ownedChangeCount: clearedChangeCount)
        }
        return .staged(ownedChangeCount: pasteboard.changeCount)
    }

    public func restore(_ snapshot: PasteboardSnapshot, ifOwnedChangeCount: Int) -> Bool {
        guard pasteboard.changeCount == ifOwnedChangeCount else { return false }
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return true }
        let restored: [NSPasteboardItem] = snapshot.items.map { snapshotItem in
            let item = NSPasteboardItem()
            for (rawType, data) in snapshotItem.values {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
            }
            return item
        }
        return pasteboard.writeObjects(restored)
    }
}

public struct ClipboardPasteController: Sendable {
    private let pasteboard: PasteboardAccessing

    public init(pasteboard: PasteboardAccessing = GeneralPasteboardAdapter()) {
        self.pasteboard = pasteboard
    }

    /// The text is kept only in memory and is never included in diagnostics or
    /// audit output. Restoration runs on success, error and cancellation.
    public func withTemporaryText<T>(_ text: String, operation: () throws -> T) throws -> T {
        let snapshot = pasteboard.snapshot()
        let ownedCount: Int
        switch pasteboard.replaceWithText(text) {
        case .staged(let changeCount):
            ownedCount = changeCount
        case .failedAfterMutation(let changeCount):
            guard pasteboard.restore(snapshot, ifOwnedChangeCount: changeCount) else {
                if pasteboard.changeCount != changeCount {
                    throw InteractionSafetyError.clipboardChangedExternally
                }
                throw InteractionSafetyError.clipboardRestoreFailed
            }
            throw InteractionSafetyError.clipboardWriteFailed
        }
        let result: Result<T, Error>
        do { result = .success(try operation()) }
        catch { result = .failure(error) }
        guard pasteboard.restore(snapshot, ifOwnedChangeCount: ownedCount) else {
            if pasteboard.changeCount != ownedCount { throw InteractionSafetyError.clipboardChangedExternally }
            throw InteractionSafetyError.clipboardRestoreFailed
        }
        return try result.get()
    }
}

public enum KeyboardModifier {
    public static let command = CGEventFlags.maskCommand.rawValue
    public static let shift = CGEventFlags.maskShift.rawValue
    public static let option = CGEventFlags.maskAlternate.rawValue
    public static let control = CGEventFlags.maskControl.rawValue
}

public protocol PasteDeliveryWaiting: Sendable {
    func wait(duration: TimeInterval, cancellation: InteractionCancellationChecking) throws
}

public struct BoundedPasteDeliveryWaiter: PasteDeliveryWaiting {
    public init() {}
    public func wait(duration: TimeInterval, cancellation: InteractionCancellationChecking) throws {
        let deadline = Date().addingTimeInterval(min(0.25, max(0, duration)))
        repeat {
            try cancellation.check()
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            Thread.sleep(forTimeInterval: min(0.01, remaining))
        } while true
    }
}

public struct TextInteractionController: Sendable {
    private let input: SyntheticInputDriving
    private let clipboard: ClipboardPasteController
    private let pasteWaiter: PasteDeliveryWaiting
    private let pasteDeliveryDelay: TimeInterval

    public init(
        input: SyntheticInputDriving,
        clipboard: ClipboardPasteController = ClipboardPasteController(),
        pasteWaiter: PasteDeliveryWaiting = BoundedPasteDeliveryWaiter(),
        pasteDeliveryDelay: TimeInterval = 0.08
    ) {
        self.input = input
        self.clipboard = clipboard
        self.pasteWaiter = pasteWaiter
        self.pasteDeliveryDelay = min(0.25, max(0, pasteDeliveryDelay))
    }

    public func paste(_ text: String, cancellation: InteractionCancellationChecking = NeverCanceled()) throws {
        try clipboard.withTemporaryText(text) {
            try cancellation.check()
            try input.key(code: 9, flags: KeyboardModifier.command, cancellation: cancellation) // ANSI V
            try pasteWaiter.wait(duration: pasteDeliveryDelay, cancellation: cancellation)
            try cancellation.check()
        }
    }

    public func selectAllText(cancellation: InteractionCancellationChecking = NeverCanceled()) throws {
        try input.key(code: 0, flags: KeyboardModifier.command, cancellation: cancellation) // ANSI A
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
