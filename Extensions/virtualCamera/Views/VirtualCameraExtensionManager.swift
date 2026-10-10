import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Security
import SystemExtensions

enum VirtualCameraExtensionPhase: Equatable {
    case checking
    case missingFromBundle
    case needsSigning
    case needsApplicationsFolder
    case notInstalled
    case installing
    case awaitingApproval
    case installed
    case removing
    case restartRequired
    case failed(String)

    var title: String {
        switch self {
        case .checking: "Checking Edith Camera"
        case .missingFromBundle: "Camera extension missing"
        case .needsSigning: "Needs a signed build"
        case .needsApplicationsFolder: "Move Edith to Applications"
        case .notInstalled: "Not installed"
        case .installing: "Installing"
        case .awaitingApproval: "Waiting for your approval"
        case .installed: "Installed"
        case .removing: "Removing"
        case .restartRequired: "Restart required"
        case .failed: "Install failed"
        }
    }

    var detail: String {
        switch self {
        case .checking:
            "Looking for the Edith Camera extension."
        case .missingFromBundle:
            "Download Edith Camera from Extensions, then try again."
        case .needsSigning:
            "The downloaded camera needs a valid macOS signing profile. Download the latest Edith Camera release, then try again."
        case .needsApplicationsFolder:
            "macOS installs camera extensions only from apps in the Applications folder."
        case .notInstalled:
            "Install Edith Camera so Zoom, Meet, FaceTime and other apps can pick it."
        case .installing:
            "Asking macOS to install Edith Camera."
        case .awaitingApproval:
            "Allow Edith Camera in System Settings, under General, Login Items & Extensions, Camera Extensions."
        case .installed:
            "Choose Edith Camera as the camera in any video app."
        case .removing:
            "Asking macOS to remove Edith Camera."
        case .restartRequired:
            "Restart macOS to finish changing Edith Camera. Its provider remains owned until the change completes."
        case .failed(let message):
            message
        }
    }

    var canInstall: Bool {
        switch self {
        case .notInstalled, .failed: true
        default: false
        }
    }
}

struct VirtualCameraExtensionEnvironment {
    var bundleURL: URL
    var hasInstallEntitlement: () -> Bool
    var deviceVisible: () -> Bool
    var canPrepareLocation = false

    static var live: VirtualCameraExtensionEnvironment {
        VirtualCameraExtensionEnvironment(
            bundleURL: Bundle.main.bundleURL,
            hasInstallEntitlement: { VirtualCameraExtensionManager.selfHasEntitlement() },
            deviceVisible: {
                VirtualCameraSink(extensionIdentifier: VirtualCameraExtensionManager.identifier)
                    .isInstalled
            })
    }
}

@MainActor
final class VirtualCameraExtensionManager: NSObject, ObservableObject {
    nonisolated static let installEntitlement = "com.apple.developer.system-extension.install"
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")

    nonisolated static var identifier: String {
        VirtualCameraIdentity.extensionIdentifier(forApplication: AppBuildIdentity.application)
    }

    @Published private(set) var phase: VirtualCameraExtensionPhase = .checking

    private let environment: VirtualCameraExtensionEnvironment
    private let client: (any CameraCarrierControlling)?
    private var operationTask: Task<Void, Never>?
    private var stopped = false
    private var refreshTask: Task<Void, Never>?

    init(
        environment: VirtualCameraExtensionEnvironment = .live,
        client: (any CameraCarrierControlling)? = nil
    ) {
        self.environment = environment; self.client = client
        super.init()
        client?.changed = { [weak self] status in self?.receive(status) }
    }

    nonisolated static func phase(
        bundleContainsExtension: Bool, entitled: Bool, inApplications: Bool, deviceVisible: Bool
    ) -> VirtualCameraExtensionPhase {
        if deviceVisible { return .installed }
        guard bundleContainsExtension else { return .missingFromBundle }
        guard entitled else { return .needsSigning }
        guard inApplications else { return .needsApplicationsFolder }
        return .notInstalled
    }

    var extensionBundleURL: URL {
        environment.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions")
            .appendingPathComponent(Self.identifier + ".systemextension")
    }

    var inApplicationsFolder: Bool {
        environment.canPrepareLocation
            || environment.bundleURL.standardizedFileURL.path.hasPrefix("/Applications/")
    }

    func refresh() {
        guard !stopped else { return }
        if let status = client?.currentStatus { receive(status); return }
        switch phase {
        case .installing, .removing, .restartRequired,
            .awaitingApproval where !environment.deviceVisible():
            return
        default:
            break
        }
        let next = Self.phase(
            bundleContainsExtension: FileManager.default.fileExists(
                atPath: extensionBundleURL.path),
            entitled: environment.hasInstallEntitlement(), inApplications: inApplicationsFolder,
            deviceVisible: environment.deviceVisible())
        if next != phase { phase = next }
    }

    func refreshDetached() {
        guard !stopped else { return }
        if let status = client?.currentStatus { receive(status); return }
        switch phase {
        case .installing, .removing, .restartRequired:
            return
        default:
            break
        }
        guard refreshTask == nil else { return }
        let visibleProbe = environment.deviceVisible
        let entitledProbe = environment.hasInstallEntitlement
        let extensionPath = extensionBundleURL.path
        let inApplications = inApplicationsFolder
        refreshTask = Task.detached {
            let visible = visibleProbe()
            let next = VirtualCameraExtensionManager.phase(
                bundleContainsExtension: FileManager.default.fileExists(atPath: extensionPath),
                entitled: entitledProbe(), inApplications: inApplications, deviceVisible: visible)
            await self.completeRefresh(next, deviceVisible: visible)
        }
    }

    private func completeRefresh(_ next: VirtualCameraExtensionPhase, deviceVisible: Bool) {
        refreshTask = nil
        guard !stopped else { return }
        switch phase {
        case .installing, .removing, .restartRequired:
            return
        case .awaitingApproval where !deviceVisible:
            return
        default:
            break
        }
        if next != phase { phase = next }
    }

    func install() {
        refresh()
        guard phase.canInstall, !stopped, operationTask == nil else { return }
        phase = .installing
        perform { try await $0.activate() }
    }

    func uninstall() {
        guard !stopped, operationTask == nil, phase == .installed || phase == .awaitingApproval
        else { return }
        phase = .removing
        perform { try await $0.deactivate() }
    }

    private func perform(
        _ operation: @escaping @MainActor (any CameraCarrierControlling) async throws -> Void
    ) {
        guard let client else { phase = .missingFromBundle; return }
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { operationTask = nil }
            do {
                try await operation(client)
                guard !stopped else { return }
                if let status = client.currentStatus { receive(status) }
            } catch {
                guard !stopped else { return }
                if client.currentStatus?.phase == "restartRequired" {
                    phase = .restartRequired
                } else {
                    phase = .failed(Self.message(for: error))
                }
            }
        }
    }

    private func receive(_ status: CameraCarrierStatus) {
        guard !stopped, status.isValid else { return }
        phase =
            switch status.phase {
            case "idle", "stopped": .notInstalled
            case "activating": .installing
            case "awaitingApproval": .awaitingApproval
            case "active": .installed
            case "deactivating": .removing
            case "restartRequired": .restartRequired
            default: .failed(status.message ?? "The camera change did not complete.")
            }
    }

    func shutdown() async {
        guard !stopped else { return }
        stopped = true
        client?.changed = nil
        operationTask?.cancel(); refreshTask?.cancel()
        let pending = [operationTask, refreshTask].compactMap { $0 }
        for task in pending { await task.value }
        operationTask = nil; refreshTask = nil
    }

    func openSystemSettings() {
        guard let url = Self.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    nonisolated static func selfHasEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
            let value = SecTaskCopyValueForEntitlement(task, installEntitlement as CFString, nil)
        else { return false }
        return (value as? Bool) == true
    }

    static func message(for error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == OSSystemExtensionErrorDomain,
            let code = OSSystemExtensionError.Code(rawValue: nsError.code)
        else { return error.localizedDescription }
        switch code {
        case .missingEntitlement:
            return VirtualCameraExtensionPhase.needsSigning.detail
        case .unsupportedParentBundleLocation:
            return VirtualCameraExtensionPhase.needsApplicationsFolder.detail
        case .extensionNotFound:
            return VirtualCameraExtensionPhase.missingFromBundle.detail
        case .requestCanceled:
            return "The request was canceled."
        case .authorizationRequired:
            return "macOS needs your approval before it installs Edith Camera."
        case .codeSignatureInvalid, .validationFailed:
            return
                "macOS rejected the camera extension signature. Download the latest Edith Camera release and try again."
        default:
            return error.localizedDescription
        }
    }

}
