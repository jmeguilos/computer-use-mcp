import AppKit
import CoreGraphics
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

public struct ApplicationDescriptor: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let name: String
    public let processID: Int32
    public let bundleURLPath: String?
    public let windows: [WindowDescriptor]
    public let isProtected: Bool

    public init(
        bundleIdentifier: String,
        name: String,
        processID: Int32,
        bundleURLPath: String? = nil,
        windows: [WindowDescriptor],
        isProtected: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.processID = processID
        self.bundleURLPath = bundleURLPath
        self.windows = windows
        self.isProtected = isProtected
    }
}

public struct InventorySnapshot: Codable, Equatable, Sendable {
    public let applications: [ApplicationDescriptor]
    public let displays: [DisplayIdentity]
}

public enum CaptureError: String, Error, Codable, Equatable, Sendable {
    case permissionDenied
    case windowNotFound
    case targetIdentityChanged
    case displayNotFound
    case protectedTarget
    case invalidContent
    case imageEncodingFailed
    case imageTooLarge
    case captureFailed
}

struct DisplayCaptureProtectedApplicationFingerprint: Hashable, Sendable {
    let processID: Int32
    let bundleIdentifier: String
    let processName: String
    let processStartTimeUnixMs: Int64?
    let signingIdentity: String?
}

struct DisplayCaptureProtectedWindowFingerprint: Hashable, Sendable {
    let windowID: UInt32
    let processID: Int32
    let bundleIdentifier: String
    let processName: String
    let processStartTimeUnixMs: Int64?
    let signingIdentity: String?
    let title: String?
    let frame: Rect
    let layer: Int
    let isOnScreen: Bool
}

struct DisplayCaptureProtectionSnapshot: Equatable, Sendable {
    let applications: Set<DisplayCaptureProtectedApplicationFingerprint>
    let windows: Set<DisplayCaptureProtectedWindowFingerprint>
}

struct DisplayCaptureWindowCandidate: Equatable, Sendable {
    let identity: WindowIdentity?
    let frame: Rect
    let isOnScreen: Bool
    let isCurrentHost: Bool
    let applicationIsProtected: Bool
    let surfaceIsProtected: Bool
    let ownerHasProtectedSurface: Bool
}

struct DisplayCaptureWindowAllowlist: Equatable, Sendable {
    let identities: [WindowIdentity]

    func contains(windowID: UInt32) -> Bool {
        identities.contains { $0.windowID == windowID }
    }
}

enum DisplayCaptureWindowAllowlistPolicy {
    static func freeze(
        candidates: [DisplayCaptureWindowCandidate],
        displayFrame: Rect
    ) -> DisplayCaptureWindowAllowlist {
        let display = displayFrame.cgRect
        guard isFinite(display), display.width > 0, display.height > 0 else {
            return DisplayCaptureWindowAllowlist(identities: [])
        }
        let identities = candidates.compactMap { candidate -> WindowIdentity? in
            guard let identity = candidate.identity,
                  candidate.isOnScreen,
                  !candidate.isCurrentHost,
                  !candidate.applicationIsProtected,
                  !candidate.surfaceIsProtected,
                  !candidate.ownerHasProtectedSurface else { return nil }
            let frame = candidate.frame.cgRect
            guard isFinite(frame), frame.width > 0, frame.height > 0 else { return nil }
            let intersection = frame.intersection(display)
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return nil }
            return identity
        }
        return DisplayCaptureWindowAllowlist(
            identities: Array(Set(identities)).sorted { lhs, rhs in
                if lhs.windowID != rhs.windowID { return lhs.windowID < rhs.windowID }
                if lhs.processID != rhs.processID { return lhs.processID < rhs.processID }
                return lhs.bundleIdentifier < rhs.bundleIdentifier
            }
        )
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
            rect.width.isFinite && rect.height.isFinite
    }
}

/// A display image remains untrusted until a second public ScreenCaptureKit
/// inventory proves that the protected application/window set did not change.
enum DisplayCaptureProtectionGate {
    static func release<Value>(
        _ captured: Value,
        before: DisplayCaptureProtectionSnapshot,
        after: DisplayCaptureProtectionSnapshot
    ) throws -> Value {
        guard before == after else { throw CaptureError.protectedTarget }
        return captured
    }
}

public protocol ScreenCaptureServing: Sendable {
    func inventory() async throws -> InventorySnapshot
    func captureWindow(
        windowID: UInt32,
        expectedIdentity: WindowIdentity,
        policy: ScreenshotSizingPolicy
    ) async throws -> ScreenshotPayload
    func captureDisplay(
        displayID: UInt32,
        policy: ScreenshotSizingPolicy
    ) async throws -> ScreenshotPayload
}

public final class ScreenCaptureService: ScreenCaptureServing, @unchecked Sendable {
    private let permissionChecker: SystemPermissionChecking
    private let protectedPolicy: ProtectedProcessPolicy
    private let currentProcessID: Int32
    private let bundleIdentifier: String

    public init(
        permissionChecker: SystemPermissionChecking = MacSystemPermissionChecker(),
        protectedPolicy: ProtectedProcessPolicy = ProtectedProcessPolicy(),
        currentProcessID: Int32 = ProcessInfo.processInfo.processIdentifier,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.jmeguilos.computer-use-mcp.host"
    ) {
        self.permissionChecker = permissionChecker
        self.protectedPolicy = protectedPolicy
        self.currentProcessID = currentProcessID
        self.bundleIdentifier = bundleIdentifier
    }

    public func inventory() async throws -> InventorySnapshot {
        guard permissionChecker.snapshot().screenCapture == .granted else { throw CaptureError.permissionDenied }
        let content = try await shareableContent()
        let windows = content.windows.compactMap(Self.makeWindowDescriptor)
        let grouped = Dictionary(grouping: windows, by: { $0.identity.processID })
        let applications = content.applications
            .filter {
                Self.isInventoryApplicationIdentity(
                    processID: $0.processID,
                    bundleIdentifier: $0.bundleIdentifier,
                    name: $0.applicationName,
                    ownBundleIdentifier: bundleIdentifier
                )
            }
            .map { [protectedPolicy] app in
                let isProtected = !protectedPolicy.evaluate(
                    bundleIdentifier: app.bundleIdentifier,
                    processName: app.applicationName,
                    processID: app.processID
                ).allowed
                return ApplicationDescriptor(
                    bundleIdentifier: app.bundleIdentifier,
                    name: app.applicationName,
                    processID: app.processID,
                    bundleURLPath: NSRunningApplication(processIdentifier: app.processID)?
                        .bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path,
                    windows: isProtected ? [] : (grouped[app.processID] ?? []).sorted {
                        $0.identity.windowID < $1.identity.windowID
                    },
                    isProtected: isProtected
                )
            }
            .sorted { lhs, rhs in
                let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return order == .orderedSame ? lhs.processID < rhs.processID : order == .orderedAscending
            }
        let displays = content.displays.compactMap(Self.makeDisplayIdentity).sorted { $0.displayID < $1.displayID }
        return InventorySnapshot(applications: applications, displays: displays)
    }

    static func isInventoryApplicationIdentity(
        processID: Int32,
        bundleIdentifier: String,
        name: String,
        ownBundleIdentifier: String
    ) -> Bool {
        isUsableApplicationIdentity(
            processID: processID,
            bundleIdentifier: bundleIdentifier,
            name: name
        ) && bundleIdentifier != ownBundleIdentifier
    }

    static func isUsableApplicationIdentity(
        processID: Int32,
        bundleIdentifier: String,
        name: String
    ) -> Bool {
        processID > 1 &&
            !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func captureWindow(
        windowID: UInt32,
        expectedIdentity: WindowIdentity,
        policy: ScreenshotSizingPolicy = ScreenshotSizingPolicy()
    ) async throws -> ScreenshotPayload {
        guard permissionChecker.snapshot().screenCapture == .granted else { throw CaptureError.permissionDenied }
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }),
              let descriptor = Self.makeWindowDescriptor(window) else { throw CaptureError.windowNotFound }
        guard Self.matchesExpectedIdentity(descriptor, expectedIdentity: expectedIdentity) else {
            throw CaptureError.targetIdentityChanged
        }
        guard protectedPolicy.evaluate(descriptor).allowed else { throw CaptureError.protectedTarget }
        let transform = try ScreenshotTransform.make(
            sourceSize: descriptor.frame.size,
            globalOrigin: descriptor.frame.origin,
            policy: policy
        )
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await captureImage(
            filter: filter,
            configuration: Self.configuration(for: transform, singleWindow: true)
        )
        return try Self.payload(image: image, transform: transform, maximumDecodedBytes: policy.maximumDecodedBytes)
    }

    public func captureDisplay(
        displayID: UInt32,
        policy: ScreenshotSizingPolicy = ScreenshotSizingPolicy()
    ) async throws -> ScreenshotPayload {
        try Task.checkCancellation()
        guard permissionChecker.snapshot().screenCapture == .granted else { throw CaptureError.permissionDenied }
        let content = try await shareableContent()
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == displayID }),
              let descriptor = Self.makeDisplayIdentity(display) else { throw CaptureError.displayNotFound }
        let beforeProtection = protectionSnapshot(content)
        let transform = try ScreenshotTransform.make(
            sourceSize: descriptor.logicalSize,
            globalOrigin: descriptor.frame.origin,
            policy: policy
        )

        // Freeze the exact prevalidated window set. ScreenCaptureKit's
        // including-windows filter cannot admit an application/window created
        // after this inventory, closing the transient launch/ABA gap in a
        // denylist filter. By public API design this omits the desktop
        // background, Dock, and menu bar; the output canvas and coordinates
        // remain the selected display's full logical geometry.
        let protectedWindows = content.windows.filter(isProtectedSurface)
        let protectedWindowProcessIDs = Set(protectedWindows.compactMap { window -> Int32? in
            guard let application = window.owningApplication else { return nil }
            return application.processID
        })
        let candidates = content.windows.map { window -> DisplayCaptureWindowCandidate in
            let application = window.owningApplication
            let applicationIsProtected = application.map {
                protectedPolicy.excludesApplicationFromDisplayCapture(
                    bundleIdentifier: $0.bundleIdentifier,
                    processName: $0.applicationName,
                    processID: $0.processID
                )
            } ?? true
            return DisplayCaptureWindowCandidate(
                identity: Self.makeWindowDescriptor(window)?.identity,
                frame: Rect(window.frame),
                isOnScreen: window.isOnScreen,
                isCurrentHost: application?.processID == currentProcessID ||
                    application?.bundleIdentifier == bundleIdentifier,
                applicationIsProtected: applicationIsProtected,
                surfaceIsProtected: isProtectedSurface(window),
                ownerHasProtectedSurface: application.map {
                    protectedWindowProcessIDs.contains($0.processID)
                } ?? true
            )
        }
        let allowlist = DisplayCaptureWindowAllowlistPolicy.freeze(
            candidates: candidates,
            displayFrame: descriptor.frame
        )
        let includedWindows = content.windows.filter { allowlist.contains(windowID: $0.windowID) }
        let filter = SCContentFilter(display: display, including: includedWindows)
        filter.includeMenuBar = false
        let image = try await captureImage(
            filter: filter,
            configuration: Self.configuration(for: transform, singleWindow: false)
        )
        try Task.checkCancellation()

        // The inclusion allowlist is tied to `content`, so new windows cannot
        // enter this frame. Re-inventory before encoding as defense in depth
        // and release only when the protected-surface set (including process
        // generation/signing identity) is stable. A failed post-check discards
        // the image and fails closed.
        let afterContent = try await shareableContent()
        try Task.checkCancellation()
        guard permissionChecker.snapshot().screenCapture == .granted else { throw CaptureError.permissionDenied }
        guard let afterDisplay = afterContent.displays.first(where: { $0.displayID == displayID }),
              Self.makeDisplayIdentity(afterDisplay) == descriptor else {
            throw CaptureError.displayNotFound
        }
        let verifiedImage = try DisplayCaptureProtectionGate.release(
            image,
            before: beforeProtection,
            after: protectionSnapshot(afterContent)
        )
        try Task.checkCancellation()
        let payload = try Self.payload(
            image: verifiedImage,
            transform: transform,
            maximumDecodedBytes: policy.maximumDecodedBytes
        )
        try Task.checkCancellation()
        return payload
    }

    private func protectionSnapshot(_ content: SCShareableContent) -> DisplayCaptureProtectionSnapshot {
        let applications = Set(content.applications.compactMap { application -> DisplayCaptureProtectedApplicationFingerprint? in
            let excluded = application.processID == currentProcessID ||
                protectedPolicy.excludesApplicationFromDisplayCapture(
                    bundleIdentifier: application.bundleIdentifier,
                    processName: application.applicationName,
                    processID: application.processID
                )
            guard excluded else { return nil }
            let running = NSRunningApplication(processIdentifier: application.processID)
            return DisplayCaptureProtectedApplicationFingerprint(
                processID: application.processID,
                bundleIdentifier: application.bundleIdentifier,
                processName: application.applicationName,
                processStartTimeUnixMs: running?.launchDate.map {
                    Int64($0.timeIntervalSince1970 * 1_000)
                },
                signingIdentity: ProcessCodeIdentity.designatedRequirementDigest(
                    processID: application.processID
                )
            )
        })

        let windows = Set(content.windows.compactMap { window -> DisplayCaptureProtectedWindowFingerprint? in
            let application = window.owningApplication
            guard application?.processID != currentProcessID else { return nil }
            guard isProtectedSurface(window) else { return nil }
            let running = application.flatMap { NSRunningApplication(processIdentifier: $0.processID) }
            return DisplayCaptureProtectedWindowFingerprint(
                windowID: window.windowID,
                processID: application?.processID ?? 0,
                bundleIdentifier: application?.bundleIdentifier ?? "",
                processName: application?.applicationName ?? "Unknown",
                processStartTimeUnixMs: running?.launchDate.map {
                    Int64($0.timeIntervalSince1970 * 1_000)
                },
                signingIdentity: application.flatMap {
                    ProcessCodeIdentity.designatedRequirementDigest(processID: $0.processID)
                },
                title: window.title,
                frame: Rect(window.frame),
                layer: window.windowLayer,
                isOnScreen: window.isOnScreen
            )
        })
        return DisplayCaptureProtectionSnapshot(applications: applications, windows: windows)
    }

    private func isProtectedSurface(_ window: SCWindow) -> Bool {
        guard let application = window.owningApplication else { return true }
        let decision = protectedPolicy.evaluateSurface(
            bundleIdentifier: application.bundleIdentifier,
            processName: application.applicationName,
            processID: application.processID,
            title: window.title
        )
        return !decision.allowed || window.windowLayer < 0 || window.windowLayer > 100
    }

    private func shareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
                if let content { continuation.resume(returning: content) }
                else { continuation.resume(throwing: error ?? CaptureError.invalidContent) }
            }
        }
    }

    private func captureImage(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? CaptureError.captureFailed) }
            }
        }
    }

    static func matchesExpectedIdentity(
        _ descriptor: WindowDescriptor,
        expectedIdentity: WindowIdentity
    ) -> Bool {
        descriptor.identity == expectedIdentity
    }

    private static func configuration(for transform: ScreenshotTransform, singleWindow: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = Int(transform.outputSize.width)
        configuration.height = Int(transform.outputSize.height)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.shouldBeOpaque = true
        configuration.ignoreShadowsSingleWindow = singleWindow
        configuration.ignoreShadowsDisplay = !singleWindow
        configuration.ignoreGlobalClipSingleWindow = singleWindow
        return configuration
    }

    static func payload(
        image: CGImage,
        transform: ScreenshotTransform,
        maximumDecodedBytes: Int = 5 * 1_024 * 1_024
    ) throws -> ScreenshotPayload {
        guard maximumDecodedBytes > 0 else { throw CaptureError.imageTooLarge }
        var candidate = image
        var candidateTransform = try transform.replacingOutputSize(
            Size(width: Double(image.width), height: Double(image.height))
        )
        for _ in 0..<16 {
            let data = try pngData(candidate)
            if data.count <= maximumDecodedBytes {
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                return ScreenshotPayload(
                    mimeType: UTType.png.preferredMIMEType ?? "image/png",
                    data: data.base64EncodedString(),
                    width: candidate.width,
                    height: candidate.height,
                    sha256: digest,
                    transform: candidateTransform,
                    decodedByteCount: data.count
                )
            }
            guard candidate.width > 1 || candidate.height > 1 else { break }
            let byteFactor = sqrt(Double(maximumDecodedBytes) / Double(data.count))
            let factor = min(0.85, max(0.25, byteFactor * 0.94))
            let width = max(1, Int(floor(Double(candidate.width) * factor)))
            let height = max(1, Int(floor(Double(candidate.height) * factor)))
            guard width < candidate.width || height < candidate.height else { break }
            candidate = try resize(candidate, width: width, height: height)
            candidateTransform = try transform.replacingOutputSize(
                Size(width: Double(width), height: Double(height))
            )
        }
        throw CaptureError.imageTooLarge
    }

    private static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.imageEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyPNGInterlaceType: 0] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.imageEncodingFailed }
        return data as Data
    }

    private static func resize(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw CaptureError.imageEncodingFailed }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage() else { throw CaptureError.imageEncodingFailed }
        return output
    }

    static func makeWindowDescriptor(_ window: SCWindow) -> WindowDescriptor? {
        guard let app = window.owningApplication,
              Self.isUsableApplicationIdentity(
                processID: app.processID,
                bundleIdentifier: app.bundleIdentifier,
                name: app.applicationName
              ),
              let signingIdentity = ProcessCodeIdentity.designatedRequirementDigest(processID: app.processID),
              let launchDate = NSRunningApplication(processIdentifier: app.processID)?.launchDate,
              let identity = try? WindowIdentity(
                windowID: window.windowID,
                processID: app.processID,
                bundleIdentifier: app.bundleIdentifier,
                ownerName: app.applicationName,
                signingIdentity: signingIdentity,
                processStartTimeUnixMs: Int64(launchDate.timeIntervalSince1970 * 1_000)
              ) else { return nil }
        return try? WindowDescriptor(
            identity: identity,
            title: window.title,
            frame: Rect(window.frame),
            layer: window.windowLayer,
            isOnScreen: window.isOnScreen,
            isActive: window.isActive
        )
    }

    static func makeDisplayIdentity(_ display: SCDisplay) -> DisplayIdentity? {
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let pixelWidth = Double(mode?.pixelWidth ?? display.width)
        let pixelHeight = Double(mode?.pixelHeight ?? display.height)
        // The frame is global logical points and preserves negative origins.
        let logical = Size(display.frame.size)
        let scaleX = logical.width > 0 ? pixelWidth / logical.width : 1
        let scaleY = logical.height > 0 ? pixelHeight / logical.height : 1
        return try? DisplayIdentity(
            displayID: display.displayID,
            frame: Rect(display.frame),
            logicalSize: logical,
            pixelSize: Size(width: pixelWidth, height: pixelHeight),
            pointPixelScaleX: scaleX,
            pointPixelScaleY: scaleY,
            name: "Display \(display.displayID)",
            isMain: CGDisplayIsMain(display.displayID) != 0,
            isMirrored: CGDisplayMirrorsDisplay(display.displayID) != kCGNullDirectDisplay
        )
    }
}
