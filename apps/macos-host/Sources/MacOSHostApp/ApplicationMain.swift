import AppKit
import MacOSHostCore

@MainActor
private final class ControllerReference {
    private var value: HostController?
    func set(_ controller: HostController) { value = controller }
    func stop(grantID: UUID) async { await value?.stop(grantID: grantID) }
}

@main
@MainActor
final class ComputerUseMCPHostApplication: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var server: HostSocketServer?
    private var controller: HostController?
    private var consentStore: PersistentAppConsentStore?
    private var preferencesStore: PersistentHostPreferencesStore?
    private var settingsWindow: ComputerControlWindowController?
    private var statusItem: NSStatusItem?
    private var statusSummaryItem: NSMenuItem?
    private var screenStatusItem: NSMenuItem?
    private var accessibilityStatusItem: NSMenuItem?
    private var developmentWarningItem: NSMenuItem?
    private var appControlItem: NSMenuItem?
    private var activeGrantsItem: NSMenuItem?
    private var emergencyStopItem: NSMenuItem?
    private var refreshTimer: Timer?
    private var screenPermissionAttempted = false
    private var accessibilityPermissionAttempted = false
    private var sourceDevelopmentBuild = false
    private var rememberedByUIIdentifier: [String: PersistentAppConsent] = [:]
    private var rememberedUIIdentifierByConsentKey: [String: String] = [:]
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        do {
            try startHost()
            configureSettingsWindow()
            startRefreshTimer()
            Task {
                await refreshPresentation()
                await presentInitialSetupIfNeeded()
            }
        } catch {
            presentStartupError(error)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        server?.stop()
    }

    private func startHost() throws {
        let configuration = try SocketConfiguration.resolved()
        let token = try RuntimeCredentialStore(configuration: configuration).prepare()
        let preferences = try PersistentHostPreferencesStore(
            url: PersistentHostPreferencesStore.defaultURL()
        )
        let verifier: PeerCodeVerifying
        switch PeerVerifierPolicy.select(
            signingIdentity: try CurrentCodeIdentity.signingIdentity(),
            sourceAuthorizationValid: DevelopmentModeAuthorization.validate(configuration: configuration)
        ) {
        case let .release(teamIdentifier):
            verifier = try ReleasePeerCodeVerifier(teamIdentifier: teamIdentifier)
            sourceDevelopmentBuild = false
        case .sourceDevelopment:
            verifier = ExplicitDevelopmentPeerCodeVerifier(explicitlyEnabled: true)
            sourceDevelopmentBuild = true
        case .denied:
            throw LocalSecurityError.developmentModeDisabled
        }

        let audit = try FileAuditStore(url: FileAuditStore.defaultURL())
        let consent = try PersistentAppConsentStore(url: PersistentAppConsentStore.defaultURL())
        let controllerReference = ControllerReference()
        let indicator = MacControlIndicator { grantID in
            await controllerReference.stop(grantID: grantID)
        }
        let stopToken = InteractionStopToken()
        let controller = HostController(
            controlPolicy: preferences,
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
        self.preferencesStore = preferences
        self.server = server
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "cursorarrow.rays",
            accessibilityDescription: "Computer Use MCP Host"
        )

        let menu = NSMenu()
        menu.delegate = self
        let summary = NSMenuItem(title: "Host: Starting", action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        statusSummaryItem = summary

        let screen = NSMenuItem(title: "Screen Recording: Checking", action: nil, keyEquivalent: "")
        screen.isEnabled = false
        menu.addItem(screen)
        screenStatusItem = screen

        let accessibility = NSMenuItem(title: "Accessibility: Checking", action: nil, keyEquivalent: "")
        accessibility.isEnabled = false
        menu.addItem(accessibility)
        accessibilityStatusItem = accessibility
        let development = NSMenuItem(
            title: "Source development build — test data only",
            action: nil,
            keyEquivalent: ""
        )
        development.isEnabled = false
        development.isHidden = true
        menu.addItem(development)
        developmentWarningItem = development
        menu.addItem(.separator())

        let appControl = NSMenuItem(
            title: "General App Access",
            action: #selector(toggleAppControlFromMenu),
            keyEquivalent: ""
        )
        appControl.target = self
        menu.addItem(appControl)
        appControlItem = appControl

        let settings = NSMenuItem(
            title: "Computer Control Settings…",
            action: #selector(openComputerControlSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let saved = NSMenuItem(
            title: "Saved App Access…",
            action: #selector(openComputerControlSettings),
            keyEquivalent: ""
        )
        saved.target = self
        menu.addItem(saved)
        menu.addItem(.separator())

        let grants = NSMenuItem(title: "Active grants: 0", action: nil, keyEquivalent: "")
        grants.isEnabled = false
        menu.addItem(grants)
        activeGrantsItem = grants

        let stop = NSMenuItem(
            title: "Emergency Stop",
            action: #selector(emergencyStop),
            keyEquivalent: "."
        )
        stop.target = self
        stop.isEnabled = false
        menu.addItem(stop)
        emergencyStopItem = stop
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Computer Use MCP Host",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    private func configureSettingsWindow() {
        let window = ComputerControlWindowController()
        window.onGeneralAccessChanged = { [weak self] enabled in
            self?.setGeneralAppAccess(enabled)
        }
        window.onScreenVisibilityAction = { [weak self] in
            self?.handleScreenVisibilityAction()
        }
        window.onAppInteractionAction = { [weak self] in
            self?.handleAppInteractionAction()
        }
        window.onRemoveRememberedApp = { [weak self] identifier in
            self?.removeRememberedApp(identifier)
        }
        window.onRemoveAllRememberedApps = { [weak self] in
            self?.removeAllRememberedApps()
        }
        window.onCheckAgain = { [weak self] in
            Task { await self?.refreshPresentation() }
        }
        window.onDone = { [weak self] in
            Task {
                guard let self, let preferencesStore = self.preferencesStore else { return }
                do {
                    try await preferencesStore.markCurrentOnboardingCompleted()
                    await self.refreshPresentation()
                    self.settingsWindow?.closeAfterSuccessfulCompletion()
                } catch {
                    self.presentSettingsError(
                        title: "Could not finish setup",
                        message: "The protected onboarding setting could not be saved. Setup remains incomplete; repair the settings file and try again."
                    )
                    await self.refreshPresentation()
                }
            }
        }
        settingsWindow = window
    }

    private func configureSessionLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.willSleepNotification,
            NSWorkspace.willPowerOffNotification,
            NSWorkspace.screensDidSleepNotification,
        ] {
            center.addObserver(
                self,
                selector: #selector(sessionBecameUnsafe(_:)),
                name: name,
                object: nil
            )
        }
    }

    private func startRefreshTimer() {
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard self?.settingsWindow?.window?.isVisible == true else { return }
                await self?.refreshPresentation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func presentInitialSetupIfNeeded() async {
        guard let preferencesStore else { return }
        let preferences = await preferencesStore.snapshot()
        let snapshot = permissions.snapshot()
        let forced = ProcessInfo.processInfo.arguments.contains("--onboarding")
        let onboardingIncomplete =
            preferences.onboardingRevision < HostPreferences.currentOnboardingRevision
        let needsAttention =
            !preferences.anyAppControlEnabled || !snapshot.isReadyForInteractiveControl
        if onboardingIncomplete || (forced && needsAttention) {
            settingsWindow?.present()
        }
    }

    private func refreshPresentation() async {
        guard let preferencesStore else { return }
        let preferences = await preferencesStore.snapshot()
        let snapshot = permissions.snapshot()
        let presentation = ComputerControlPresentation(
            permissions: snapshot,
            anyAppControlEnabled: preferences.anyAppControlEnabled
        )
        let remembered = await rememberedAppRows()
        let activeGrantCount = await controller?.activeGrantCount() ?? 0

        let state = ComputerControlWindowState(
            sourceDevelopmentBuild: sourceDevelopmentBuild,
            generalAccessEnabled: preferences.anyAppControlEnabled,
            overallStatusText: overallStatusText(presentation.availability),
            screenVisibility: screenCardState(snapshot),
            appInteraction: interactionCardState(snapshot),
            rememberedApps: remembered
        )
        settingsWindow?.render(state)
        renderStatusMenu(
            preferences: preferences,
            permissions: snapshot,
            availability: presentation.availability,
            activeGrantCount: activeGrantCount
        )
    }

    private func rememberedAppRows() async -> [ComputerControlRememberedApp] {
        guard let consentStore else {
            rememberedByUIIdentifier = [:]
            rememberedUIIdentifierByConsentKey = [:]
            return []
        }
        let records = await consentStore.all()
        var mapping: [String: PersistentAppConsent] = [:]
        var identifiersByKey: [String: String] = [:]
        let rows = records.map { record -> ComputerControlRememberedApp in
            let consentKey = [
                String(record.recordVersion),
                record.policy.rawValue,
                record.requesterBundleIdentifier ?? "",
                record.requesterSigningIdentity ?? "",
                record.bundleIdentifier,
                record.signingIdentity,
            ].joined(separator: "\n")
            let identifier = rememberedUIIdentifierByConsentKey[consentKey] ?? UUID().uuidString
            identifiersByKey[consentKey] = identifier
            mapping[identifier] = record
            let matching = NSRunningApplication.runningApplications(
                withBundleIdentifier: record.bundleIdentifier
            ).first { application in
                ProcessCodeIdentity.designatedRequirementDigest(
                    processID: application.processIdentifier
                ) == record.signingIdentity
            }
            let name = matching?.localizedName ?? "App unavailable"
            let capabilitySummary = NativeAccessPromptText.capabilityLabels(record.capabilities)
                .joined(separator: ", ")
            let targetSigner = Self.signingFingerprint(record.signingIdentity)
            let access: String
            if record.policy == .autoGrantUniqueWindow,
               let requester = record.requesterBundleIdentifier,
               let requesterSigningIdentity = record.requesterSigningIdentity {
                access = "Requester: \(requester) • requester sig " +
                    "\(Self.signingFingerprint(requesterSigningIdentity)) • " +
                    "target sig \(targetSigner) • \(capabilitySummary)"
            } else {
                access = "Legacy prompt-only decision • target sig \(targetSigner) • " +
                    "Fresh Always Allow approval required • \(capabilitySummary)"
            }
            return ComputerControlRememberedApp(
                id: identifier,
                displayName: name,
                bundleIdentifier: record.bundleIdentifier,
                accessSummary: access
            )
        }
        rememberedByUIIdentifier = mapping
        rememberedUIIdentifierByConsentKey = identifiersByKey
        return rows
    }

    private static func signingFingerprint(_ identity: String) -> String {
        let sanitized = NativeUISanitizer.escaped(
            identity,
            maximumInputUTF16: 512,
            maximumOutputUTF16: 1_024
        )
        guard sanitized.count > 12 else { return sanitized }
        return String(sanitized.prefix(12)) + "…"
    }

    private func renderStatusMenu(
        preferences: HostPreferences,
        permissions snapshot: PermissionSnapshot,
        availability: ComputerControlAvailability,
        activeGrantCount: Int
    ) {
        statusSummaryItem?.title = "Host: \(overallStatusText(availability))"
        screenStatusItem?.title =
            "Screen Recording: \(snapshot.screenCapture == .granted ? "Allowed" : "Needs access")"
        accessibilityStatusItem?.title =
            "Accessibility: \(snapshot.accessibility == .granted && snapshot.eventPosting == .granted ? "Allowed" : "Needs access")"
        appControlItem?.state = preferences.anyAppControlEnabled ? .on : .off
        developmentWarningItem?.isHidden = !sourceDevelopmentBuild
        activeGrantsItem?.title = "Active grants: \(activeGrantCount)"
        emergencyStopItem?.isEnabled = activeGrantCount > 0
        switch availability {
        case .ready:
            statusItem?.button?.contentTintColor = .systemGreen
        case .needsSystemAccess:
            statusItem?.button?.contentTintColor = .systemOrange
        case .disabled:
            statusItem?.button?.contentTintColor = .secondaryLabelColor
        }
    }

    private func overallStatusText(_ availability: ComputerControlAvailability) -> String {
        switch availability {
        case .ready: return "Ready"
        case .needsSystemAccess: return "Needs macOS access"
        case .disabled: return "App control is off"
        }
    }

    private func screenCardState(_ snapshot: PermissionSnapshot) -> ComputerControlPermissionCardState {
        if snapshot.screenCapture == .granted {
            return ComputerControlPermissionCardState(
                statusText: "Ready",
                detailText: "The host may capture only a separately approved window or display.",
                tone: .ready
            )
        }
        return ComputerControlPermissionCardState(
            statusText: screenPermissionAttempted ? "Check System Settings" : "Needs access",
            detailText: "Required to return an approved target image. The host does not retain screenshot history.",
            actionTitle: screenPermissionAttempted ? "Open Settings…" : "Ask macOS…",
            tone: screenPermissionAttempted ? .caution : .needsAction
        )
    }

    private func interactionCardState(_ snapshot: PermissionSnapshot) -> ComputerControlPermissionCardState {
        if snapshot.accessibility == .granted && snapshot.eventPosting == .granted {
            return ComputerControlPermissionCardState(
                statusText: "Ready",
                detailText: "The host may inspect controls and perform input only within an approved target.",
                tone: .ready
            )
        }
        if snapshot.accessibility == .granted {
            return ComputerControlPermissionCardState(
                statusText: "Limited",
                detailText: "Accessibility is allowed, but some pointer and keyboard actions are not available yet.",
                actionTitle: "Open Settings…",
                tone: .caution
            )
        }
        return ComputerControlPermissionCardState(
            statusText: accessibilityPermissionAttempted ? "Waiting for macOS" : "Needs access",
            detailText: "Required to inspect accessible controls and perform approved input. Input Monitoring is not requested.",
            actionTitle: accessibilityPermissionAttempted ? "Open Settings…" : "Ask macOS…",
            tone: accessibilityPermissionAttempted ? .waiting : .needsAction
        )
    }

    @objc private func applicationBecameActive() {
        Task { await refreshPresentation() }
    }

    @objc private func sessionBecameUnsafe(_ notification: Notification) {
        guard SessionLifecyclePolicy.shouldRevoke(for: notification.name) else { return }
        Task {
            await controller?.emergencyStop()
            await refreshPresentation()
        }
    }

    @objc private func openComputerControlSettings() {
        settingsWindow?.present()
        Task { await refreshPresentation() }
    }

    @objc private func toggleAppControlFromMenu() {
        setGeneralAppAccess(!(appControlItem?.state == .on))
    }

    private func setGeneralAppAccess(_ enabled: Bool) {
        Task {
            do {
                try await preferencesStore?.setAnyAppControlEnabled(enabled)
                if !enabled { await controller?.emergencyStop() }
                await refreshPresentation()
            } catch {
                if !enabled {
                    await preferencesStore?.forceDisableForCurrentProcess()
                    await controller?.emergencyStop()
                }
                presentSettingsError(
                    title: "Could not update app access",
                    message: enabled
                        ? "The protected host preference could not be saved. App access remains off."
                        : "The protected host preference could not be saved. This host process was stopped and latched off; repair the settings file before relying on a restart."
                )
                await refreshPresentation()
            }
        }
    }

    private func handleScreenVisibilityAction() {
        let snapshot = permissions.snapshot()
        if snapshot.screenCapture == .granted { return }
        if screenPermissionAttempted {
            openPrivacyPane("Privacy_ScreenCapture")
        } else {
            screenPermissionAttempted = true
            _ = permissions.request(.screenCapture)
        }
        Task { await refreshPresentation() }
    }

    private func handleAppInteractionAction() {
        let snapshot = permissions.snapshot()
        if snapshot.accessibility == .granted && snapshot.eventPosting == .granted { return }
        if accessibilityPermissionAttempted || snapshot.accessibility == .granted {
            openPrivacyPane("Privacy_Accessibility")
        } else {
            accessibilityPermissionAttempted = true
            _ = permissions.request(.accessibility)
        }
        Task { await refreshPresentation() }
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func removeRememberedApp(_ identifier: String) {
        guard let record = rememberedByUIIdentifier[identifier] else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove saved app access?"
        let requester = record.requesterBundleIdentifier.map {
            " from \(NativeUISanitizer.escaped($0, maximumInputUTF16: 512, maximumOutputUTF16: 1_024))"
        } ?? ""
        alert.informativeText =
            "Future requests\(requester) for \(NativeUISanitizer.escaped(record.bundleIdentifier, maximumInputUTF16: 512, maximumOutputUTF16: 1_024)) will require a fresh app decision. Active grants are unchanged."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                try await consentStore?.revoke(record)
            } catch {
                presentSettingsError(
                    title: "Could not remove saved access",
                    message: "The protected approval file was not changed."
                )
            }
            await refreshPresentation()
        }
    }

    private func removeAllRememberedApps() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove all saved app access?"
        alert.informativeText =
            "Every future request will require a fresh app decision and an exact target choice. Active grants are unchanged."
        alert.addButton(withTitle: "Remove All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                try await consentStore?.revokeAll()
            } catch {
                presentSettingsError(
                    title: "Could not remove saved access",
                    message: "The protected approval file was not changed."
                )
            }
            await refreshPresentation()
        }
    }

    @objc private func emergencyStop() {
        Task {
            await controller?.emergencyStop()
            await refreshPresentation()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func menuWillOpen(_ menu: NSMenu) {
        Task { await refreshPresentation() }
    }

    private func presentSettingsError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentStartupError(_ error: Error) {
        statusItem?.button?.contentTintColor = .systemRed
        let message: String
        switch error {
        case LocalSecurityError.developmentModeDisabled:
            message = "The source-development authorization is missing or unsafe. Run the local setup command again."
        case is HostPreferencesStoreError:
            message = "The protected host settings file is missing, malformed, or has unsafe permissions. Repair it with the local setup command."
        default:
            message = "The private runtime, helper identity, or local socket could not be validated. Run the doctor command for exact remediation."
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Computer Use MCP Host could not start"
        alert.informativeText = message
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }
}
