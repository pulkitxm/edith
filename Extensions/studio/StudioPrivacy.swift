import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

private struct StudioPrivacyKey: EnvironmentKey {
    static let defaultValue: SurfacePrivacyState? = nil
}

extension EnvironmentValues {
    var studioPrivacy: SurfacePrivacyState? {
        get { self[StudioPrivacyKey.self] }
        set { self[StudioPrivacyKey.self] = newValue }
    }
}

private struct StudioPrivacyCover: ViewModifier {
    @Environment(\.studioPrivacy) private var privacy

    @ViewBuilder func body(content: Content) -> some View {
        if privacy?.hides(.ability("studio")) ?? false {
            content
                .compositingGroup()
                .blur(radius: UIScale.pt(28))
                .overlay {
                    Color.black.opacity(0.45).allowsHitTesting(false)
                }
                .privacySensitive(true)
        } else {
            content
        }
    }
}

extension View {
    func studioPrivacyCover() -> some View { modifier(StudioPrivacyCover()) }
}
