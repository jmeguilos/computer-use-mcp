import AppKit
import CoreGraphics
import Foundation

@main
final class ComputerUseMCPFixtureApplication: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private struct RuntimeSmokeFailure: Error, CustomStringConvertible {
        let description: String
    }

    private var primaryWindow: NSWindow!
    private var inspectorWindow: NSWindow!
    private var statusField: NSTextField!
    private var counterField: NSTextField!
    private var lastActionField: NSTextField!
    private var duplicateWindow: NSWindow?
    private var fixturePopover: NSPopover?
    private var counter = 42
    private let runtimeSmokeReportURL: URL?

    override init() {
        runtimeSmokeReportURL = Self.runtimeSmokeReportURL(from: CommandLine.arguments)
        super.init()
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = ComputerUseMCPFixtureApplication()
        app.delegate = delegate
        app.setActivationPolicy(delegate.runtimeSmokeReportURL == nil ? .regular : .accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindows()
        primaryWindow.orderFront(nil)
        inspectorWindow.orderFront(nil)
        if let runtimeSmokeReportURL {
            // This mode deliberately inspects and operates only objects owned by
            // this process. It does not use AX APIs, ScreenCaptureKit, CGEvent,
            // or any other API that needs a macOS privacy permission.
            DispatchQueue.main.async { [weak self] in
                self?.runRuntimeSmoke(reportURL: runtimeSmokeReportURL)
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            emitManifest()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow,
              closing === primaryWindow || closing === inspectorWindow else { return }
        NSApp.terminate(nil)
    }

    private func buildWindows() {
        let displayID = CGMainDisplayID()
        let display = CGDisplayBounds(displayID)
        let primaryTop = clamped(CGRect(x: 120, y: 120, width: 720, height: 520), inside: display)
        let inspectorTop = clamped(CGRect(x: 880, y: 180, width: 520, height: 360), inside: display)
        let screen = NSScreen.main ?? NSScreen.screens[0]

        primaryWindow = makeWindow(
            title: "Computer Use MCP Fixture — Primary",
            topLeftFrame: primaryTop,
            screen: screen
        )
        primaryWindow.contentView = primaryContent(size: primaryWindow.contentLayoutRect.size)

        inspectorWindow = makeWindow(
            title: "Computer Use MCP Fixture — Inspector",
            topLeftFrame: inspectorTop,
            screen: screen
        )
        inspectorWindow.contentView = inspectorContent(size: inspectorWindow.contentLayoutRect.size)
    }

    private func makeWindow(title: String, topLeftFrame: CGRect, screen: NSScreen) -> NSWindow {
        let display = CGDisplayBounds(CGMainDisplayID())
        let appKitFrame = CGRect(
            x: screen.frame.minX + (topLeftFrame.minX - display.minX),
            y: screen.frame.maxY - (topLeftFrame.minY - display.minY) - topLeftFrame.height,
            width: topLeftFrame.width,
            height: topLeftFrame.height
        )
        let window = NSWindow(
            contentRect: appKitFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.setFrame(appKitFrame, display: false)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier(title.contains("Primary") ? "fixture.window.primary" : "fixture.window.inspector")
        return window
    }

    private func primaryContent(size: CGSize) -> NSView {
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        let heading = label("Deterministic account-controls fixture", frame: NSRect(x: 24, y: size.height - 48, width: 420, height: 24))
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        view.addSubview(heading)

        let box = NSBox(frame: NSRect(x: 24, y: 34, width: size.width - 48, height: size.height - 96))
        box.title = "Account Controls"
        box.setAccessibilityIdentifier("fixture.accountControls")
        view.addSubview(box)

        let usernameLabel = label("Username", frame: NSRect(x: 28, y: 338, width: 120, height: 22))
        box.addSubview(usernameLabel)
        let username = NSTextField(frame: NSRect(x: 160, y: 334, width: 260, height: 26))
        username.stringValue = "Ada Lovelace"
        username.setAccessibilityIdentifier("fixture.username")
        username.setAccessibilityLabel("Username")
        box.addSubview(username)

        let passcodeLabel = label("Passcode", frame: NSRect(x: 28, y: 296, width: 120, height: 22))
        box.addSubview(passcodeLabel)
        let passcode = NSSecureTextField(frame: NSRect(x: 160, y: 292, width: 260, height: 26))
        passcode.stringValue = "fixture-secret"
        passcode.setAccessibilityIdentifier("fixture.passcode")
        passcode.setAccessibilityLabel("Passcode")
        box.addSubview(passcode)

        let notifications = NSButton(checkboxWithTitle: "Enable notifications", target: nil, action: nil)
        notifications.frame = NSRect(x: 28, y: 246, width: 250, height: 24)
        notifications.state = .on
        notifications.setAccessibilityIdentifier("fixture.notifications")
        notifications.setAccessibilityLabel("Enable notifications")
        box.addSubview(notifications)

        let environmentLabel = label("Environment", frame: NSRect(x: 28, y: 202, width: 120, height: 22))
        box.addSubview(environmentLabel)
        let environment = NSPopUpButton(frame: NSRect(x: 160, y: 198, width: 180, height: 26))
        environment.addItems(withTitles: ["Development", "Staging", "Production"])
        environment.selectItem(withTitle: "Staging")
        environment.setAccessibilityIdentifier("fixture.environment")
        environment.setAccessibilityLabel("Environment")
        box.addSubview(environment)

        let confidenceLabel = label("Confidence", frame: NSRect(x: 28, y: 158, width: 120, height: 22))
        box.addSubview(confidenceLabel)
        let confidence = NSSlider(value: 0.75, minValue: 0, maxValue: 1, target: nil, action: nil)
        confidence.frame = NSRect(x: 160, y: 156, width: 260, height: 22)
        confidence.setAccessibilityIdentifier("fixture.confidence")
        confidence.setAccessibilityLabel("Confidence")
        box.addSubview(confidence)

        let run = NSButton(title: "Run harmless action", target: self, action: #selector(runHarmlessAction))
        run.frame = NSRect(x: 28, y: 100, width: 160, height: 30)
        run.setAccessibilityIdentifier("fixture.run")
        run.setAccessibilityLabel("Run harmless action")
        box.addSubview(run)

        let duplicateA = NSButton(title: "Duplicate action", target: self, action: #selector(duplicateAction(_:)))
        duplicateA.tag = 1
        duplicateA.frame = NSRect(x: 210, y: 100, width: 140, height: 30)
        duplicateA.setAccessibilityIdentifier("fixture.duplicate.a")
        duplicateA.setAccessibilityLabel("Duplicate action")
        box.addSubview(duplicateA)
        let duplicateB = NSButton(title: "Duplicate action", target: self, action: #selector(duplicateAction(_:)))
        duplicateB.tag = 2
        duplicateB.frame = NSRect(x: 362, y: 100, width: 140, height: 30)
        duplicateB.setAccessibilityIdentifier("fixture.duplicate.b")
        duplicateB.setAccessibilityLabel("Duplicate action")
        box.addSubview(duplicateB)

        statusField = label("Ready", frame: NSRect(x: 160, y: 54, width: 300, height: 22))
        statusField.setAccessibilityIdentifier("fixture.status")
        statusField.setAccessibilityLabel("Status")
        box.addSubview(label("Status", frame: NSRect(x: 28, y: 54, width: 120, height: 22)))
        box.addSubview(statusField)
        return view
    }

    private func inspectorContent(size: CGSize) -> NSView {
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        let heading = label("Fixture Inspector", frame: NSRect(x: 24, y: size.height - 48, width: 320, height: 24))
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        view.addSubview(heading)
        addRow(to: view, label: "Build", value: "fixture-2026-08-29", id: "fixture.build", y: 238)
        counterField = addRow(to: view, label: "Counter", value: "42", id: "fixture.counter", y: 190)
        let increment = NSButton(title: "Increment counter", target: self, action: #selector(incrementCounter))
        increment.frame = NSRect(x: 156, y: 136, width: 160, height: 30)
        increment.setAccessibilityIdentifier("fixture.increment")
        increment.setAccessibilityLabel("Increment counter")
        view.addSubview(increment)
        lastActionField = addRow(to: view, label: "Last action", value: "None", id: "fixture.lastAction", y: 84)

        let duplicate = NSButton(title: "Duplicate title", target: self, action: #selector(openDuplicateTitleWindow))
        duplicate.frame = NSRect(x: 24, y: 30, width: 142, height: 30)
        duplicate.setAccessibilityIdentifier("fixture.openDuplicateWindow")
        duplicate.setAccessibilityLabel("Open duplicate-title window")
        view.addSubview(duplicate)
        let sheet = NSButton(title: "Open sheet", target: self, action: #selector(openFixtureSheet))
        sheet.frame = NSRect(x: 178, y: 30, width: 112, height: 30)
        sheet.setAccessibilityIdentifier("fixture.openSheet")
        sheet.setAccessibilityLabel("Open fixture sheet")
        view.addSubview(sheet)
        let popover = NSButton(title: "Open popover", target: self, action: #selector(openFixturePopover(_:)))
        popover.frame = NSRect(x: 302, y: 30, width: 132, height: 30)
        popover.setAccessibilityIdentifier("fixture.openPopover")
        popover.setAccessibilityLabel("Open fixture popover")
        view.addSubview(popover)
        return view
    }

    @discardableResult
    private func addRow(to view: NSView, label text: String, value: String, id: String, y: CGFloat) -> NSTextField {
        view.addSubview(label(text, frame: NSRect(x: 28, y: y, width: 116, height: 22)))
        let field = label(value, frame: NSRect(x: 156, y: y, width: 320, height: 22))
        field.setAccessibilityIdentifier(id)
        field.setAccessibilityLabel(text)
        view.addSubview(field)
        return field
    }

    private func label(_ value: String, frame: NSRect) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.frame = frame
        return field
    }

    @objc private func runHarmlessAction() {
        statusField.stringValue = "Completed"
        lastActionField.stringValue = "Run harmless action"
    }

    @objc private func duplicateAction(_ sender: NSButton) {
        lastActionField.stringValue = "Duplicate action \(sender.tag == 1 ? "A" : "B")"
    }

    @objc private func incrementCounter() {
        counter += 1
        counterField.stringValue = String(counter)
        lastActionField.stringValue = "Increment counter"
    }

    @objc private func openDuplicateTitleWindow() {
        if let duplicateWindow { duplicateWindow.orderFront(nil); return }
        let primaryTop = topLeftFrame(primaryWindow.frame)
        let requested = CGRect(
            x: (primaryTop["x"] ?? 120) + 48,
            y: (primaryTop["y"] ?? 120) + 48,
            width: 420,
            height: 240
        )
        let window = makeWindow(
            title: "Computer Use MCP Fixture — Primary",
            topLeftFrame: clamped(requested, inside: CGDisplayBounds(CGMainDisplayID())),
            screen: NSScreen.main ?? NSScreen.screens[0]
        )
        window.setAccessibilityIdentifier("fixture.window.duplicateTitle")
        let content = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        let text = label("Duplicate window title; unique AX identifier fixture.window.duplicateTitle", frame: NSRect(x: 24, y: 120, width: 370, height: 48))
        text.setAccessibilityIdentifier("fixture.duplicateWindow.label")
        content.addSubview(text)
        window.contentView = content
        duplicateWindow = window
        window.orderFront(nil)
        lastActionField.stringValue = "Opened duplicate-title window"
    }

    @objc private func openFixtureSheet() {
        guard primaryWindow.attachedSheet == nil else { return }
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        sheet.title = "Computer Use MCP Fixture — Sheet"
        sheet.setAccessibilityIdentifier("fixture.sheet")
        let content = NSView(frame: sheet.contentLayoutRect)
        let prompt = label("Deterministic sheet value: Review 17", frame: NSRect(x: 24, y: 90, width: 300, height: 24))
        prompt.setAccessibilityIdentifier("fixture.sheet.value")
        content.addSubview(prompt)
        let dismiss = NSButton(title: "Dismiss sheet", target: self, action: #selector(dismissFixtureSheet))
        dismiss.frame = NSRect(x: 230, y: 28, width: 126, height: 30)
        dismiss.setAccessibilityIdentifier("fixture.sheet.dismiss")
        content.addSubview(dismiss)
        sheet.contentView = content
        primaryWindow.beginSheet(sheet)
        lastActionField.stringValue = "Opened sheet"
    }

    @objc private func dismissFixtureSheet() {
        if let sheet = primaryWindow.attachedSheet { primaryWindow.endSheet(sheet) }
    }

    @objc private func openFixturePopover(_ sender: NSButton) {
        let popover = fixturePopover ?? NSPopover()
        let controller = NSViewController()
        controller.preferredContentSize = NSSize(width: 280, height: 100)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 100))
        let text = label("Popover token: amber-23", frame: NSRect(x: 22, y: 38, width: 236, height: 24))
        text.setAccessibilityIdentifier("fixture.popover.value")
        content.addSubview(text)
        controller.view = content
        popover.contentViewController = controller
        popover.behavior = .transient
        fixturePopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        lastActionField.stringValue = "Opened popover"
    }

    private func runRuntimeSmoke(reportURL: URL) {
        var completedChecks: [String] = []
        do {
            let baselineWindows = NSApp.windows.filter { window in
                window === primaryWindow || window === inspectorWindow
            }
            try require(baselineWindows.count == 2, "baseline-window-count", completed: &completedChecks)
            try require(
                primaryWindow.title == "Computer Use MCP Fixture — Primary" &&
                    inspectorWindow.title == "Computer Use MCP Fixture — Inspector",
                "baseline-window-titles",
                completed: &completedChecks
            )
            try require(
                primaryWindow.accessibilityIdentifier() == "fixture.window.primary" &&
                    inspectorWindow.accessibilityIdentifier() == "fixture.window.inspector",
                "baseline-window-identifiers",
                completed: &completedChecks
            )

            let username = try fixtureView("fixture.username", as: NSTextField.self)
            let passcode = try fixtureView("fixture.passcode", as: NSSecureTextField.self)
            let notifications = try fixtureView("fixture.notifications", as: NSButton.self)
            let environment = try fixtureView("fixture.environment", as: NSPopUpButton.self)
            let confidence = try fixtureView("fixture.confidence", as: NSSlider.self)
            try require(
                username.stringValue == "Ada Lovelace" &&
                    passcode.stringValue == "fixture-secret" &&
                    notifications.state == .on &&
                    environment.titleOfSelectedItem == "Staging" &&
                    confidence.doubleValue == 0.75 &&
                    statusField.stringValue == "Ready" &&
                    counterField.stringValue == "42" &&
                    lastActionField.stringValue == "None",
                "deterministic-control-values",
                completed: &completedChecks
            )

            try fixtureView("fixture.run", as: NSButton.self).performClick(nil)
            try require(
                statusField.stringValue == "Completed" && lastActionField.stringValue == "Run harmless action",
                "harmless-action",
                completed: &completedChecks
            )

            try fixtureView("fixture.duplicate.a", as: NSButton.self).performClick(nil)
            try require(lastActionField.stringValue == "Duplicate action A", "duplicate-action-a", completed: &completedChecks)
            try fixtureView("fixture.duplicate.b", as: NSButton.self).performClick(nil)
            try require(lastActionField.stringValue == "Duplicate action B", "duplicate-action-b", completed: &completedChecks)

            try fixtureView("fixture.increment", as: NSButton.self).performClick(nil)
            try require(
                counterField.stringValue == "43" && lastActionField.stringValue == "Increment counter",
                "counter-action",
                completed: &completedChecks
            )

            try fixtureView("fixture.openDuplicateWindow", as: NSButton.self).performClick(nil)
            try require(
                duplicateWindow?.title == primaryWindow.title &&
                    duplicateWindow?.accessibilityIdentifier() == "fixture.window.duplicateTitle" &&
                    duplicateWindow !== primaryWindow && duplicateWindow !== inspectorWindow,
                "duplicate-title-window",
                completed: &completedChecks
            )

            try fixtureView("fixture.openSheet", as: NSButton.self).performClick(nil)
            try require(
                primaryWindow.attachedSheet?.accessibilityIdentifier() == "fixture.sheet",
                "sheet-presentation",
                completed: &completedChecks
            )
            dismissFixtureSheet()
            try require(primaryWindow.attachedSheet == nil, "sheet-dismissal", completed: &completedChecks)

            let popoverButton = try fixtureView("fixture.openPopover", as: NSButton.self)
            popoverButton.performClick(nil)
            try require(
                fixturePopover?.isShown == true &&
                    descendant(withIdentifier: "fixture.popover.value", in: fixturePopover?.contentViewController?.view) != nil,
                "popover-presentation",
                completed: &completedChecks
            )
            fixturePopover?.close()

            try writeRuntimeSmokeReport(
                [
                    "schemaVersion": 1,
                    "status": "passed",
                    "mode": "in-process-appkit",
                    "baselineWindowCount": 2,
                    "exercisedWindowCount": 3,
                    "privacyPermissionsRequired": false,
                    "checks": completedChecks,
                ],
                to: reportURL
            )
        } catch {
            try? writeRuntimeSmokeReport(
                [
                    "schemaVersion": 1,
                    "status": "failed",
                    "mode": "in-process-appkit",
                    "privacyPermissionsRequired": false,
                    "checks": completedChecks,
                    "error": String(describing: error),
                ],
                to: reportURL
            )
        }
        NSApp.terminate(nil)
    }

    private func fixtureView<T: NSView>(_ identifier: String, as type: T.Type) throws -> T {
        for root in [primaryWindow.contentView, inspectorWindow.contentView] {
            if let view = descendant(withIdentifier: identifier, in: root) as? T {
                return view
            }
        }
        throw RuntimeSmokeFailure(description: "missing or incorrectly typed fixture view: \(identifier)")
    }

    private func descendant(withIdentifier identifier: String, in root: NSView?) -> NSView? {
        guard let root else { return nil }
        if root.accessibilityIdentifier() == identifier { return root }
        for child in root.subviews {
            if let match = descendant(withIdentifier: identifier, in: child) { return match }
        }
        return nil
    }

    private func require(
        _ condition: @autoclosure () -> Bool,
        _ name: String,
        completed: inout [String]
    ) throws {
        guard condition() else { throw RuntimeSmokeFailure(description: "runtime smoke check failed: \(name)") }
        completed.append(name)
    }

    private func writeRuntimeSmokeReport(_ report: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: report,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: [.atomic])
    }

    private static func runtimeSmokeReportURL(from arguments: [String]) -> URL? {
        guard let flagIndex = arguments.firstIndex(of: "--runtime-smoke-report"),
              arguments.indices.contains(flagIndex + 1) else { return nil }
        let path = arguments[flagIndex + 1]
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: false)
    }

    private func emitManifest() {
        let displayID = CGMainDisplayID()
        let manifest: [String: Any] = [
            "fixture": "Computer Use MCP Fixture",
            "bundleId": "com.jmeguilos.computer-use-mcp.fixture",
            "displayId": "display-\(displayID)",
            "windows": [
                ["title": primaryWindow.title, "framePoints": topLeftFrame(primaryWindow.frame)],
                ["title": inspectorWindow.title, "framePoints": topLeftFrame(inspectorWindow.frame)],
            ],
            "stableValues": [
                "fixture.username": "Ada Lovelace",
                "fixture.notifications": 1,
                "fixture.environment": "Staging",
                "fixture.confidence": 0.75,
                "fixture.status": "Ready",
                "fixture.build": "fixture-2026-08-29",
                "fixture.counter": 42,
                "fixture.lastAction": "None",
                "fixture.sheet.value": "Review 17",
                "fixture.popover.value": "amber-23",
            ],
            "scenarios": [
                "duplicateTitleWindow": [
                    "trigger": "fixture.openDuplicateWindow",
                    "title": "Computer Use MCP Fixture — Primary",
                    "windowIdentifier": "fixture.window.duplicateTitle",
                ],
                "sheet": ["trigger": "fixture.openSheet", "identifier": "fixture.sheet"],
                "popover": ["trigger": "fixture.openPopover", "identifier": "fixture.popover.value"],
            ],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) {
            print(line)
            fflush(stdout)
        }
    }

    private func topLeftFrame(_ frame: CGRect) -> [String: Double] {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let display = CGDisplayBounds(CGMainDisplayID())
        return [
            "x": display.minX + frame.minX - screen.frame.minX,
            "y": display.minY + screen.frame.maxY - frame.maxY,
            "width": frame.width,
            "height": frame.height,
        ]
    }

    private func clamped(_ frame: CGRect, inside display: CGRect) -> CGRect {
        CGRect(
            x: min(max(frame.minX, display.minX), max(display.minX, display.maxX - frame.width)),
            y: min(max(frame.minY, display.minY), max(display.minY, display.maxY - frame.height)),
            width: min(frame.width, display.width),
            height: min(frame.height, display.height)
        )
    }
}
