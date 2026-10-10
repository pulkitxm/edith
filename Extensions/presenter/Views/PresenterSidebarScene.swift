import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct PresenterSidebarScene: View {
    var presentation: ControlPresentation? = nil
    @AppStorage(AppStorageKeys.Presenter.mode, store: SharedDefaults.store) private var manual =
        false
    @AppStorage(AppStorageKeys.Presenter.enabled, store: SharedDefaults.store) private var enabled =
        false
    @State private var hovering = false

    @MainActor static func controller(
        _ input: NSDictionary, presentation: ControlPresentation? = nil
    ) -> NSViewController? {
        guard input["location"] as? String == "sidebar.utility",
            input["section"] as? String == "privacy"
        else { return nil }
        if let presentation {
            return NSHostingController(
                rootView: ExtensionPageHost {
                    ControlSettingsHost(presentation: presentation) {
                        PresenterSidebarScene(presentation: presentation)
                    }
                })
        }
        return NSHostingController(rootView: ExtensionPageHost { PresenterSidebarScene() })
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { manual },
            set: {
                manual = $0
                IPC.post(IPC.Name.settingsChanged)
                if !$0 { presentation?.perform("stop") }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(0)) {
            Text("Presenter mode").font(.system(size: UIScale.pt(13), weight: .semibold))
                .padding(.bottom, UIScale.pt(10))
            Button {
                binding.wrappedValue.toggle()
            } label: {
                HStack(spacing: UIScale.pt(12)) {
                    Text("Presenter mode").font(.system(size: UIScale.pt(12.5)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("", isOn: binding).labelsHidden().toggleStyle(.switch)
                        .controlSize(.small).allowsHitTesting(false)
                }.frame(maxWidth: .infinity).padding(.horizontal, UIScale.pt(8))
                    .padding(.vertical, UIScale.pt(8))
                    .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
                    .contentShape(Rectangle())
            }.buttonStyle(.edith(.borderless)).onHover { hovering = $0 }
                .disabled(!enabled).accessibilityLabel("Manual presenter mode")
                .accessibilityValue(manual ? "On" : "Off")
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(0)) {
                    ForEach(PresenterPrivacy.allCases) { category in
                        Divider()
                        PresenterPrivacyQuickToggle(category: category)
                    }
                }
            }.frame(maxHeight: UIScale.pt(360))
        }.padding(UIScale.pt(14)).frame(width: UIScale.pt(250))
    }
}
