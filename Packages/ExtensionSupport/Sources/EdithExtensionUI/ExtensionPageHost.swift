import EdithExtensionSupport
import SwiftUI

public struct ExtensionPageHost<Content: View>: View {
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var theme =
        "accent"
    @AppStorage(AppStorageKeys.General.appearance, store: SharedDefaults.store) private
        var appearance = "system"
    @AppStorage(WindowZoom.defaultsKey, store: SharedDefaults.store) private var zoom = 1.0
    @State private var router = WindowRouter()
    private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    public var body: some View {
        GeometryReader { geometry in
            NavigationRouteHost(router: router) { content() }
                .environment(\.compactLayout, geometry.size.width < UIScale.pt(720))
                .tint(themeColor(theme))
                .tracksWindowVisibility()
        }
        .onAppear {
            InputFocus.install()
            UIScale.apply(zoom); applyAppearance(appearance)
        }
        .onChange(of: zoom) { UIScale.apply(zoom) }
        .onChange(of: appearance) { applyAppearance(appearance) }
    }
}
