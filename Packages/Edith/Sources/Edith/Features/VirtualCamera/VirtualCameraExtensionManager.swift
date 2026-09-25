import AppKit
import EdithCameraSupport
import EdithCore
import EdithKit
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
        case .failed: "Install failed"
        }
    }

    var detail: String {
        switch self {
        case .checking:
            "Looking for the Edith Camera extension."
        case .missingFromBundle:
            "This copy of Edith was built without the camera extension. Rebuild it with build.sh."
        case .needsSigning:
            "macOS only installs camera extensions from apps signed with the System Extension entitlement. Build Edith with EDITH_APP_PROVISIONING_PROFILE and EDITH_CAMERA_PROVISIONING_PROFILE, as described in the Virtual Camera guide. The preview, framing and scenes work in the meantime."
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
    private var pendingRemoval = false

    init(environment: VirtualCameraExtensionEnvironment = .live) {
        self.environment = environment
        super.init()
    }

    static func phase(
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
        environment.bundleURL.standardizedFileURL.path.hasPrefix("/Applications/")
    }

    func refresh() {
        switch phase {
        case .installing, .removing,
            .awaitingApproval where !environment.deviceVisible():
            return
        default:
            break
        }
        phase = Self.phase(
            bundleContainsExtension: FileManager.default.fileExists(
                atPath: extensionBundleURL.path),
            entitled: environment.hasInstallEntitlement(), inApplications: inApplicationsFolder,
            deviceVisible: environment.deviceVisible())
    }

    func install() {
        refresh()
        guard phase.canInstall else { return }
        phase = .installing
        pendingRemoval = false
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.identifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func uninstall() {
        guard phase == .installed || phase == .awaitingApproval else { return }
        phase = .removing
        pendingRemoval = true
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Self.identifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
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
                "macOS rejected the camera extension signature. Rebuild Edith with matching provisioning profiles."
        default:
            return error.localizedDescription
        }
    }

    fileprivate func finish(_ result: OSSystemExtensionRequest.Result) {
        if result == .willCompleteAfterReboot {
            phase = .failed("Restart the Mac to finish updating Edith Camera.")
            return
        }
        phase = pendingRemoval ? .notInstalled : .installed
        pendingRemoval = false
    }

    fileprivate func fail(_ error: Error) {
        pendingRemoval = false
        phase = .failed(Self.message(for: error))
    }
}

extension VirtualCameraExtensionManager: OSSystemExtensionRequestDelegate {
    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated { phase = .awaitingApproval }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        MainActor.assumeIsolated { finish(result) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        MainActor.assumeIsolated { fail(error) }
    }
}
