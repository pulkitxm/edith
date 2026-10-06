import EdithCore
import EdithKit
import EdithLidAwakeSupport
import Security
import ServiceManagement
import SwiftUI

@MainActor
final class MainAppDelegate: NSObject, NSApplicationDelegate {
    private var quitObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var settingsIPCObserver: NSObjectProtocol?
    private var settingsBroadcastPending = false
    private var lastUsageEnabled: Bool?
    private var appStarted = false
    private var launchCleanupTask: Task<Void, Never>?
    private var helperMaintenanceTask: Task<Void, Never>?
    private let lidAwakeDaemonRegistrar = LidAwakeDaemonRegistrar()
    private let agentRegistrar = AgentRegistrar()
    private let postLaunch = StartupCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard AgentService.usesCustomService || InstalledLocation.permitsLaunch() else {
            InstalledLocation.refuseLaunch()
            return
        }
        let launchTrace = PerformanceTrace.begin(.startup, "main.launch")
        defer { PerformanceTrace.end(launchTrace) }
        applyAppearance(
            SharedDefaults.store.string(forKey: AppStorageKeys.General.appearance) ?? "system")
        InputFocus.install()
        TextEditingCommands.install()
        ScrollForwarding.install()
        FinderUndoBridge.start()
        startApp()
    }

    private func startApp() {
        guard !appStarted else {
            showInitialWindow()
            return
        }
        appStarted = true
        UserShellEnvironment.shared.enable(after: .seconds(4))
        ExtensionDefaultsMigration.migrate()
        AttentionRepository.sink = AgentAttentionSink()
        AttentionContextReporter.shared.start()
        AttentionExtensionInstaller.refreshIfOutdated()
        IPCTransport.enable()
        AgentCommandRouting.enable()
        if !AgentService.usesCustomService {
            agentRegistrar.registerAndRestartIfStale()
        }
        applyConfiguredActivationPolicy()
        showInitialWindow()
        PerformanceTrace.event(.mainThread, "main.initialWindow")
        quitObserver = IPC.observe(IPC.Name.quitMainApp) {
            AppRuntimeCenter().perform(.quit) { NSApp.terminate(nil) }
        }
        CLIWindowBridge.install()
        lastUsageEnabled =
            SharedDefaults.store.object(forKey: AppStorageKeys.Tabs.usageEnabled) as? Bool
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: SharedDefaults.store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSettingsChange()
            }
        }
        settingsIPCObserver = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
            SharedDefaults.store.synchronize()
            self?.refreshConfiguredSettings()
        }
        postLaunch.start([
            StartupPhase(name: "main.launchCleanup") { [weak self] in
                guard !AgentService.usesCustomService, let self else { return }
                self.launchCleanupTask?.cancel()
                self.launchCleanupTask = Task.detached(priority: .utility) {
                    DataRoot.prepare()
                    DataRoot.pruneLogs()
                    Repo.prepareStoredPaths()
                    RetiredLicenseCleanup.run()
                }
            },
            StartupPhase(name: "main.helper") { [weak self] in
                guard !AgentService.usesCustomService, let self else { return }
                self.helperMaintenanceTask?.cancel()
                self.helperMaintenanceTask = Task.detached(priority: .utility) {
                    await launchHelperIfNeeded()
                }
            },
            StartupPhase(name: "main.sectionMenu") { SectionWindowMenu.install() },
            StartupPhase(name: "main.lidAwakeDaemon") { [weak self] in
                guard !AgentService.usesCustomService, !AppBuildIdentity.isDevelopment, let self
                else { return }
                self.lidAwakeDaemonRegistrar.register()
            },
        ])
    }

    private func handleSettingsChange() {
        refreshConfiguredSettings()
        scheduleSettingsChangedBroadcast()
    }

    private func refreshConfiguredSettings() {
        applyAppearance(
            SharedDefaults.store.string(forKey: AppStorageKeys.General.appearance) ?? "system")
        let usageEnabled =
            SharedDefaults.store.object(forKey: AppStorageKeys.Tabs.usageEnabled) as? Bool
        if usageEnabled != lastUsageEnabled {
            lastUsageEnabled = usageEnabled
            DashboardModel.shared.syncExtensionState()
        }
    }

    private func applyConfiguredActivationPolicy() {
        if BackgroundTesting.isActive {
            NSApp.setActivationPolicy(.accessory)
            return
        }
        let showDockIcon =
            SharedDefaults.store.object(forKey: AppStorageKeys.General.showDockIcon) as? Bool
            ?? true
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }

    private func showInitialWindow() {
        if BackgroundTesting.isActive || !OnboardingFlow.shouldShowOnboarding() {
            MainWindow.open()
        } else {
            OnboardingWindow.open()
        }
    }

    private func scheduleSettingsChangedBroadcast() {
        guard !settingsBroadcastPending else { return }
        settingsBroadcastPending = true
        ProcessInfo.processInfo.disableSuddenTermination()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                self?.flushSettingsChangedBroadcast()
            }
        }
    }

    private func flushSettingsChangedBroadcast() {
        guard settingsBroadcastPending else { return }
        settingsBroadcastPending = false
        IPC.post(IPC.Name.settingsChanged)
        ProcessInfo.processInfo.enableSuddenTermination()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        VideoExportBackground.userReturned()
        if !appStarted {
            startApp()
        } else if !hasVisibleWindows {
            showInitialWindow()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if VideoExportBackground.defersQuit(sender) { return .terminateCancel }
        if #available(macOS 15.0, *), TimeLapseRecorder.shared.defersQuit(sender) {
            return .terminateCancel
        }
        guard appStarted, AppBuildIdentity.isDevelopment, !AgentService.usesCustomService else {
            return .terminateNow
        }
        postLaunch.cancel()
        helperMaintenanceTask?.cancel()
        Task { [agentRegistrar, helperMaintenanceTask] in
            await helperMaintenanceTask?.value
            for helper in NSRunningApplication.runningApplications(
                withBundleIdentifier: AppBuildIdentity.helper)
            {
                helper.terminate()
            }
            await agentRegistrar.unloadDevelopmentAgent()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let settingsIPCObserver { IPC.stopObserving(settingsIPCObserver) }
        CalendarPermission.shutdown()
        flushSettingsChangedBroadcast()
        launchCleanupTask?.cancel()
        helperMaintenanceTask?.cancel()
        postLaunch.cancel()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if #available(macOS 15.0, *),
            TimeLapseRecorder.shared.recording || TimeLapseRecorder.shared.busy
                || TimeLapseRecorder.shared.library.exporting
        {
            return false
        }
        return !VideoExportBackground.keepsAppOpenAfterLastWindowClosed()
    }
}

@MainActor
private final class LidAwakeDaemonRegistrar {
    private static let fingerprintKey = "lidAwakePrivilegedHelperFingerprint"

    private let service = SMAppService.daemon(plistName: LidAwakePrivilegedService.plistName)
    private var registrationInFlight = false
    private var microphoneSyncInFlight = false
    private var microphoneSynced = false
    private lazy var approvalRefresher = ApprovalStatusRefresher { [weak self] in
        self?.publishStatus()
    }

    func register() {
        guard !registrationInFlight else { return }
        let fingerprint = helperFingerprint()
        switch service.status {
        case .enabled, .requiresApproval:
            guard let fingerprint else {
                publishStatus()
                return
            }
            guard UserDefaults.standard.string(forKey: Self.fingerprintKey) != fingerprint
            else {
                publishStatus()
                return
            }
            registrationInFlight = true
            service.unregister { [weak self] error in
                let failed = error != nil
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.registrationInFlight = false
                        guard !failed else {
                            self.publishStatus()
                            return
                        }
                        self.registerCurrent(fingerprint: fingerprint)
                    }
                }
            }
        case .notRegistered, .notFound:
            registerCurrent(fingerprint: fingerprint)
        @unknown default:
            publishStatus()
        }
        publishStatus()
    }

    private func registerCurrent(fingerprint: String?) {
        do {
            try service.register()
            persist(fingerprint)
            publishStatus()
        } catch {
            let failure = error as NSError
            if service.status == .requiresApproval
                || (failure.domain == "SMAppServiceErrorDomain" && failure.code == 1)
            {
                persist(fingerprint)
            } else {
                NSLog(
                    "Service Management registration failed (%@ %ld): %@", failure.domain,
                    failure.code, failure.localizedDescription)
            }
            publishStatus()
        }
    }

    private func publishStatus() {
        let state: String =
            switch service.status {
            case .notRegistered: "notRegistered"
            case .enabled: "enabled"
            case .requiresApproval: "awaitingApproval"
            case .notFound: "notFound"
            @unknown default: "notFound"
            }
        SharedDefaults.store.setIfChanged(state, forKey: LidAwakePrivilegedService.stateKey)
        approvalRefresher.update(awaitingApproval: state == "awaitingApproval")
        if state == "enabled" { synchronizeMeetingMicrophone() }
    }

    private func synchronizeMeetingMicrophone() {
        guard !microphoneSyncInFlight, !microphoneSynced else { return }
        microphoneSyncInFlight = true
        let connection = NSXPCConnection(
            machServiceName: LidAwakePrivilegedService.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: LidAwakePrivilegedProtocol.self)
        connection.resume()
        let finish: @Sendable (NSError?) -> Void = { [weak self] error in
            connection.invalidate()
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.microphoneSyncInFlight = false
                self.microphoneSynced = message == nil
                SharedDefaults.store.setIfChanged(
                    message ?? "", forKey: MeetingMicrophoneDeployment.errorKey)
            }
        }
        guard
            let proxy = connection.remoteObjectProxyWithErrorHandler({ finish($0 as NSError) })
                as? LidAwakePrivilegedProtocol
        else {
            finish(
                NSError(
                    domain: MeetingMicrophoneDeployment.identifier, code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Edith’s privileged helper is unavailable."
                    ]))
            return
        }
        proxy.synchronizeMeetingMicrophone(reply: finish)
    }

    private func persist(_ fingerprint: String?) {
        if let fingerprint {
            UserDefaults.standard.set(fingerprint, forKey: Self.fingerprintKey)
        }
    }

    private func helperFingerprint() -> String? {
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/PrivilegedHelperTools")
            .appendingPathComponent(LidAwakePrivilegedService.bundleIdentifier)
        var code: SecStaticCode?
        guard
            SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess,
            let code
        else { return nil }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
            let values = information as? [CFString: Any],
            let data = values[kSecCodeInfoUnique] as? Data
        else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }
}

public struct EdithApp: App {
    @NSApplicationDelegateAdaptor(MainAppDelegate.self) private var delegate

    public init() {}

    public var body: some Scene {
        Settings {
            SettingsRedirect()
        }
    }
}

private struct SettingsRedirect: View {
    var body: some View {
        Color.clear
            .frame(width: UIScale.pt(1), height: UIScale.pt(1))
            .onAppear {
                SharedDefaults.store.set(
                    MainDestination.settings.rawValue,
                    forKey: AppStorageKeys.General.mainWindowSection)
                DispatchQueue.main.async {
                    for window in NSApp.windows
                    where window.identifier?.rawValue.contains("Settings") == true
                        || window.title == "Edith Settings"
                    {
                        window.close()
                    }
                    MainWindow.open()
                }
            }
    }
}
