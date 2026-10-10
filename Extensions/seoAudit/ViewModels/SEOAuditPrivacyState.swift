import EdithExtensionSupport
import Observation

@MainActor @Observable final class SEOAuditPrivacyState {
    static let shared = SEOAuditPrivacyState()
    private var state: SurfacePrivacyState?
    init() {
        if let channel = ExtensionSharedState.current {
            state = SurfacePrivacyState(channel: channel)
        }
    }
    var hidden: Bool {
        Self.hidden(values: state?.values ?? [:])
    }
    static func hidden(values: [String: String]) -> Bool {
        values["active"] == "1" && values["blurSiteAudit"] != "0"
    }
    func shutdown() { state?.shutdown(); state = nil }
}
