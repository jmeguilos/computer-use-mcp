import AppKit
import MacOSHostCore

@MainActor
private final class ControllerReference {
    private var value: HostController?
    func set(_ controller: HostController) { value = controller }
    func stop() async {
        await value?.emergencyStop()
    }
    func stop(grantID: UUID) async {
        await value?.stop(grantID: grantID)
    }
}

@main
@MainActor
final class ComputerUseMCPHostApplication: NSObject, NSApplicationDelegate {
    private var server: HostSocketServer?
    private var controller: HostController?
    private var statusItem: NSStatusItem?
    private var consentStore: PersistentAppConsentStore?
    private let permissions = MacSystemPermissionChecker()

    static func main() {
        let app = NSApplication.shared
        let delegate = ComputerUseMCPHostApplication()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        configureSessionLifecycleObservers()
        do { try startHost() }
        catch { presentStartupError(error) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        server?.stop()
    }

    private func startHost() throws {
        let configuration = try SocketConfiguration.resolved()
        let token = try RuntimeCredentialStore(configuration: configuration).prepare()
        let verifier: PeerCodeVerifying
        switch PeerVerifierPolicy.select(
            signingIdentity: try CurrentCodeIdentity.signingIdentity(),
            sourceAuthorizationValid: DevelopmentModeAuthorization.validate(configuration: configuration)
        ) {
        case let .release(teamIdentifier):
            // A release-signed host always takes this branch and never honors
            // the source-development authorization marker.
            verifier = try ReleasePeerCodeVerifier(teamIdentifier: teamIdentifier)
        case .sourceDevelopment:
            verifier = ExplicitDevelopmentPeerCodeVerifier(explicitlyEnabled: true)
        case .denied:
            throw LocalSecurityError.developmentModeDisabled
        }
        let audit = try FileAuditStore(url: FileAuditStore.defaultURL())
        let consent = try PersistentAppConsentStore(url: PersistentAppConsentStore.defaultURL())
        let controllerReference = ControllerReference()
        let indicator = MacControlIndicator { grantID in await controllerReference.stop(grantID: grantID) }
        let stopToken = InteractionStopToken()
        let controller = HostController(
            accessPresenter: NativeAccessApprovalPresenter(),
            riskPresenter: NativeRiskApprovalPresenter(),
            indicator: indicator,
            stopToken: stopToken,
            auditStore: audit,
            consentStore: consent,
            auditSalt: Data(token.utf8)
        )
        controllerReference.set(controller)
        let server = HostSocketServer(
            configuration: configuration,
            authenticationToken: token,
            peerVerifier: verifier,
            handler: controller
        )
        try server.start()
        self.controller = controller
        self.consentStore = consent
        self.server = server
        updateStatusTitle()
        if ProcessInfo.processInfo.arguments.contains("--onboarding") {
            DispatchQueue.main.async { [weak self] in self?.requestPermissions() }
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "cursorarrow.rays",
            accessibilityDescription: "Computer Use MCP Host"
        )
        let menu = NSMenu()
        menu.addItem(withTitle: "Request Required Permissions…", action: #selector(requestPermissions), keyEquivalent: "")
        menu.addItem(withTitle: "Open Privacy Settings…", action: #selector(openPrivacySettings), keyEquivalent: "")
        menu.addItem(withTitle: "Clear Saved App Approvals…", action: #selector(clearSavedApprovals), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Emergency Stop", action: #selector(emergencyStop), keyEquivalent: ".")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Computer Use MCP Host", action: #selector(quit), keyEquivalent: "q")
        for menuItem in menu.items { menuItem.target = self }
        item.menu = menu
        statusItem = item
    }

    private func configureSessionLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.willSleepNotification,
            NSWorkspace.willPowerOffNotification,
            NSWorkspace.screensDidSleepNotification,
        ] {
            center.addObserver(self, selector: #selector(sessionBecameUnsafe(_:)), name: name, object: nil)
        }
    }

    @objc private func sessionBecameUnsafe(_ notification: Notification) {
        guard SessionLifecyclePolicy.shouldRevoke(for: notification.name) else { return }
        Task { await controller?.emergencyStop() }
    }

    @objc private func requestPermissions() {
        // Input Monitoring is an optional diagnostic and is never requested.
        if permissions.snapshot().screenCapture != .granted { _ = permissions.request(.screenCapture) }
        if permissions.snapshot().accessibility != .granted { _ = permissions.request(.accessibility) }
        if permissions.snapshot().eventPosting != .granted { _ = permissions.request(.eventPosting) }
        updateStatusTitle()
    }

    @objc private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func emergencyStop() { Task { await controller?.emergencyStop() } }
    @objc private func clearSavedApprovals() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear all saved app approvals?"
        alert.informativeText = "New access requests will require app approval and an exact window choice. Active grants are not changed."
        alert.addButton(withTitle: "Clear Approvals")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { try? await consentStore?.revokeAll() }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func updateStatusTitle() {
        statusItem?.button?.contentTintColor = permissions.snapshot().isReadyForInteractiveControl
            ? .systemGreen : .systemOrange
    }

    private func presentStartupError(_ error: Error) {
        statusItem?.button?.contentTintColor = .systemRed
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Computer Use MCP Host could not start"
        alert.informativeText = NativeUISanitizer.escaped(
            String(describing: error),
            maximumInputUTF16: 1_024,
            maximumOutputUTF16: 2_048
        )
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }
}
