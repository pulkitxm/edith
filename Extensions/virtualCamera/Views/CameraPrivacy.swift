import EdithExtensionSupport
import Foundation
import Observation

@MainActor @Observable
final class CameraPrivacy {
    enum Category { case camera }
    static let shared = CameraPrivacy()
    private var values: [String: String] = [:]
    @ObservationIgnored private let channel: ExtensionSharedState?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(channel: ExtensionSharedState? = .current) {
        self.channel = channel
        values = channel?.values(for: "presenter") ?? [:]
        observer = channel?.observe { [weak self] owner in
            guard owner == "presenter" else { return }
            MainActor.assumeIsolated { self?.values = channel?.values(for: "presenter") ?? [:] }
        }
    }

    func hides(_ category: Category) -> Bool {
        SurfacePrivacyState.hides(.ability("virtualCamera"), values: values)
    }

    func shutdown() { channel?.stopObserving(observer); observer = nil; values = [:] }
}
