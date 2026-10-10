import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct HerdrRemoteScene: View {
    let store: HerdrStore
    let location: String
    let target: String
    let token: UUID
    @Environment(\.automaticViewActionsEnabled) private var automaticActions

    var body: some View {
        Group {
            if !store.uiPresentations.contains(where: {
                $0.matches(location: location, target: target, token: token)
            }) {
                PageLoading(
                    state: store.inventoryReady ? .error : .loading, title: "Window unavailable",
                    message: store.inventoryFailureMessage ?? "This window has closed.",
                    layout: .editor
                ) { EmptyView() }
            } else if location == "herdr.space", let model = store.uiSpaces[target] {
                HerdrSpaceView(model: model, store: store, launchEnabled: true)
            } else if location == "herdr.agent", store.detachedTab(id: target) != nil {
                HerdrDetachedView(store: store, agentID: target, launchEnabled: true)
            } else if location == "herdr.agent.controls", store.detachedTab(id: target) != nil {
                HerdrTitlebarViewPicker(store: store, agentID: target)
            } else {
                PageLoading(
                    state: store.inventoryReady ? .error : .loading,
                    title: "Window unavailable",
                    message: store.inventoryFailureMessage ?? "This window has closed.",
                    layout: .editor
                ) { EmptyView() }
            }
        }
        .task(id: automaticActions) {
            if automaticActions { await store.watch() } else { store.stopWatching() }
        }
    }
}
