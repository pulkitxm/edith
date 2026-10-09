import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct HostSettingsPage: View {
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var theme =
        "accent"
    @AppStorage(AppStorageKeys.General.appearance, store: SharedDefaults.store) private
        var appearance = "system"
    @AppStorage(WindowZoom.defaultsKey, store: SharedDefaults.store) private var zoom = 1.0

    var body: some View {
        ExtensionPageHost {
            PageScaffold(width: .readable) {
                PageHeader("Appearance")
            } content: {
                VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                    Picker("Theme", selection: $theme) {
                        ForEach(AppTheme.allCases) {
                            Text($0.rawValue.capitalized).tag($0.rawValue)
                        }
                    }
                    EdithSegmentedPicker(
                        "Appearance", selection: $appearance, options: ["system", "light", "dark"],
                        label: { $0.capitalized })
                    LabeledContent("Zoom", value: "\(Int(zoom * 100))%")
                    Slider(value: $zoom, in: WindowZoom.range, step: WindowZoom.step)
                }
                .font(.edithText(.body))
                .padding(UIScale.pt(16))
                .edithSurface()
            }
        }
        .frame(width: 480, height: 360)
    }
}
