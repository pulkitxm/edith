import EdithExtensionSupport
import SwiftUI

public struct ExtensionPageHost<Content: View>: View {
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var theme =
        "accent"
    @AppStorage(AppStorageKeys.General.appearance, store: SharedDefaults.store) private
        var appearance = "system"
    @AppStorage(WindowZoom.defaultsKey, store: SharedDefaults.store) private var zoom = 1.0
    @State private var router = WindowRouter()
    @State private var remotePresentation: ExtensionPresentationState?
    private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
        _remotePresentation = State(initialValue: ExtensionPresentationState.current)
    }

    public var body: some View {
        Group {
            if let remotePresentation {
                page(compact: remotePresentation.compact)
                    .environment(\.extensionPresentationState, remotePresentation)
                    .fixedSize(horizontal: false, vertical: remotePresentation.intrinsic)
            } else {
                GeometryReader { geometry in
                    page(compact: geometry.size.width < UIScale.pt(720))
                }
            }
        }
        .onAppear {
            InputFocus.install()
            UIScale.apply(zoom); applyAppearance(appearance)
        }
        .onChange(of: zoom) { UIScale.apply(zoom) }
        .onChange(of: appearance) { applyAppearance(appearance) }
    }

    private func page(compact: Bool) -> some View {
        NavigationRouteHost(router: router) { content() }
            .environment(\.compactLayout, compact)
            .tint(themeColor(theme))
            .tracksWindowVisibility()
    }
}
