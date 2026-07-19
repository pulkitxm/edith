import EdithKit
import ServiceManagement
import SwiftUI

private let helperBundleIdentifier = "com.pulkit.edith.statusbar"

@MainActor
final class MainAppDelegate: NSObject, NSApplicationDelegate {
    private var quitObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var settingsChangeDebounce: Timer?
    private var licenseVerificationTimer: Timer?
    private var licenseVerificationTask: Task<Void, Never>?
    private var licenseMigrationTask: Task<Void, Never>?
    private let licenseState = LicenseState()
    private let licenseClient = LicenseClient()
    private let licenseCredentialStore = FileLicenseCredentialStore()
    private var licensedAppStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearance(SharedDefaults.store.string(forKey: "appearance") ?? "system")
        switch currentLaunchDecision() {
        case .start:
            startLicensedApp()
        case .startAndMigrate:
            startLicensedApp()
            migrateLegacyLicense()
        case .gate:
            terminateHelper()
            presentActivationGate()
        }
    }

    private func currentLaunchDecision() -> LicenseLaunchDecision {
        LicenseCoordinator.currentRiskState(credentialStore: licenseCredentialStore)
            .launchDecision
    }

    private func licenseV2Session() -> LicenseV2Session {
        LicenseV2Session(client: licenseClient, credentialStore: licenseCredentialStore)
    }

    private func migrateLegacyLicense() {
        guard licenseMigrationTask == nil else { return }
        licenseMigrationTask = Task { [weak self] in
            guard let self else { return }
            defer { licenseMigrationTask = nil }
            _ = try? await licenseV2Session().migrateFromV1()
        }
    }

    private func startLicensedApp() {
        guard !licensedAppStarted else {
            showInitialWindow()
            return
        }
        licensedAppStarted = true
        scheduleLicenseVerification()
        ExtensionDefaultsMigration.migrate()
        Repo.prepareStoredPaths()
        applyConfiguredActivationPolicy()
        launchHelperIfNeeded()
        let dashboard = DashboardModel.shared
        dashboard.syncExtensionState()
        if SharedDefaults.store.bool(forKey: "tabUsageEnabled") {
            Task { await dashboard.load() }
        }
        showInitialWindow()
        quitObserver = IPC.observe(IPC.Name.quitMainApp) {
            NSApp.terminate(nil)
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: SharedDefaults.store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                DashboardModel.shared.syncExtensionState()
                self?.scheduleSettingsChangedBroadcast()
            }
        }
        verifyLicenseInBackground()
    }

    private func applyConfiguredActivationPolicy() {
        let showDockIcon = SharedDefaults.store.object(forKey: "showDockIcon") as? Bool ?? true
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }

    private func showInitialWindow() {
        if OnboardingFlow.shouldShowOnboarding() {
            OnboardingWindow.open()
        } else {
            MainWindow.open()
        }
    }

    private func presentActivationGate() {
        NSApp.setActivationPolicy(.regular)
        for window in NSApp.windows where window.identifier != ActivationWindow.identifier {
            window.orderOut(nil)
        }
        ActivationWindow.open(licenseState: licenseState, client: licenseClient) { [weak self] in
            self?.startLicensedApp()
        }
    }

    private func verifyLicenseInBackground() {
        guard licenseVerificationTask == nil else { return }
        guard currentLaunchDecision() != .gate else {
            invalidateLicenseAndRegate()
            return
        }
        licenseVerificationTask = Task { [weak self] in
            guard let self else { return }
            defer { licenseVerificationTask = nil }
            if ((try? licenseCredentialStore.read(.refreshCredential)) ?? nil) != nil {
                try? await licenseV2Session().refresh()
                guard !Task.isCancelled else { return }
                if currentLaunchDecision() == .gate {
                    invalidateLicenseAndRegate()
                }
                return
            }
            await verifyLegacyLicense()
        }
    }

    private func verifyLegacyLicense() async {
        guard let key = try? licenseState.licenseKey(), let machine = hardwareUUID() else {
            return
        }
        do {
            let response = try await licenseClient.verify(key: key, hardwareUuid: machine)
            guard !Task.isCancelled else { return }
            guard response.ok else {
                invalidateLicenseAndRegate()
                return
            }
            do {
                try licenseState.recordSuccessfulVerification(receipt: response.receipt)
            } catch LicenseStateError.invalidReceipt {
                invalidateLicenseAndRegate()
                return
            }
            if response.receipt != nil {
                launchHelperIfNeeded()
            }
            migrateLegacyLicense()
        } catch LicenseClientError.invalidKey {
            invalidateLicenseAndRegate()
        } catch {
            return
        }
    }

    private func scheduleLicenseVerification() {
        licenseVerificationTimer?.invalidate()
        let jitter = Double.random(in: -3_600...3_600)
        licenseVerificationTimer = Timer.scheduledTimer(
            withTimeInterval: 12 * 60 * 60 + jitter, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.verifyLicenseInBackground()
                self?.scheduleLicenseVerification()
            }
        }
    }

    private func invalidateLicenseAndRegate() {
        try? licenseState.deactivate()
        for item in [
            LicenseCredentialItem.entitlement, .refreshCredential, .accessToken, .trustedTime,
        ] {
            try? licenseCredentialStore.delete(item)
        }
        stopLicensedApp()
        presentActivationGate()
    }

    private func stopLicensedApp() {
        licenseVerificationTask?.cancel()
        licenseVerificationTask = nil
        licenseMigrationTask?.cancel()
        licenseMigrationTask = nil
        licenseVerificationTimer?.invalidate()
        licenseVerificationTimer = nil
        settingsChangeDebounce?.invalidate()
        settingsChangeDebounce = nil
        if let quitObserver {
            NotificationCenter.default.removeObserver(quitObserver)
            self.quitObserver = nil
        }
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
        terminateHelper()
        licensedAppStarted = false
    }

    private func scheduleSettingsChangedBroadcast() {
        settingsChangeDebounce?.invalidate()
        settingsChangeDebounce = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            IPC.post(IPC.Name.settingsChanged)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard currentLaunchDecision() != .gate else {
            invalidateLicenseAndRegate()
            return true
        }
        if !licensedAppStarted {
            startLicensedApp()
        } else if !hasVisibleWindows {
            showInitialWindow()
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard licensedAppStarted else { return }
        guard currentLaunchDecision() != .gate else {
            invalidateLicenseAndRegate()
            return
        }
        verifyLicenseInBackground()
    }

    func applicationWillTerminate(_ notification: Notification) {
        licenseVerificationTask?.cancel()
        licenseVerificationTask = nil
        licenseMigrationTask?.cancel()
        licenseMigrationTask = nil
        licenseVerificationTimer?.invalidate()
        licenseVerificationTimer = nil
        settingsChangeDebounce?.invalidate()
        settingsChangeDebounce = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private let retiredHelperBundleIdentifiers = [
    "com.pulkit.edith.panel", "com.pulkit.edith.bar", "com.pulkit.edith.menubar",
]

private func launchHelperIfNeeded() {
    for identifier in retiredHelperBundleIdentifiers {
        let retired = SMAppService.loginItem(identifier: identifier)
        if retired.status == .enabled {
            try? retired.unregister()
        }
    }
    let service = SMAppService.loginItem(identifier: helperBundleIdentifier)
    if service.status != .enabled {
        try? service.register()
    }
    let helperURL = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Library/LoginItems/Edith.app")
    if let running = NSRunningApplication.runningApplications(
        withBundleIdentifier: helperBundleIdentifier
    ).first {
        guard let installedAt = helperInstalledDate(helperURL),
            let launchedAt = running.launchDate, launchedAt < installedAt
        else { return }
        running.forceTerminate()
        relaunchHelper(at: helperURL, after: running)
        return
    }
    NSWorkspace.shared.openApplication(
        at: helperURL, configuration: NSWorkspace.OpenConfiguration())
}

private func terminateHelper() {
    for helper in NSRunningApplication.runningApplications(
        withBundleIdentifier: helperBundleIdentifier
    ) {
        helper.forceTerminate()
    }
}

private func helperInstalledDate(_ helperURL: URL) -> Date? {
    let exec = helperURL.appendingPathComponent("Contents/MacOS/Edith")
    return (try? FileManager.default.attributesOfItem(atPath: exec.path)[.modificationDate])
        as? Date
}

private func relaunchHelper(at url: URL, after proc: NSRunningApplication) {
    DispatchQueue.global(qos: .userInitiated).async {
        for _ in 0..<50 where !proc.isTerminated {
            Thread.sleep(forTimeInterval: 0.1)
        }
        DispatchQueue.main.async {
            NSWorkspace.shared.openApplication(
                at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

@main
struct EdithApp: App {
    @NSApplicationDelegateAdaptor(MainAppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsRedirect()
        }
    }
}

private struct SettingsRedirect: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                SharedDefaults.store.set(
                    MainDestination.settings.rawValue, forKey: "mainWindowSection")
                DispatchQueue.main.async {
                    for window in NSApp.windows
                    where window.identifier?.rawValue.contains("Settings") == true
                        || window.title == "Edith Settings"
                    {
                        window.close()
                    }
                    if LicenseCoordinator.currentRiskState().launchDecision != .gate {
                        MainWindow.open()
                    }
                }
            }
    }
}
