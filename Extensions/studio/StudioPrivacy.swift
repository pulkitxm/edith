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

    func body(content: Content) -> some View {
        let hidden = privacy?.hides(.ability("studio")) ?? false
        content
            .blur(radius: hidden ? UIScale.pt(16) : 0)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
            .overlay {
                if hidden {
                    Label("Hidden while presenting", systemImage: "eye.slash")
                        .font(.edithText(.body))
                        .padding(UIScale.pt(16))
                        .background(
                            .regularMaterial, in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
                }
            }
    }
}

extension View {
    func studioPrivacyCover() -> some View { modifier(StudioPrivacyCover()) }
}
