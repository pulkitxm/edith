import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct HerdrRemoteScene: View {
    let store: HerdrStore
    let location: String
    let target: String
    let token: UUID
    @Environment(\.automaticViewActionsEnabled) private var automaticActions
    @State private var keyMonitor = HerdrPageKeyMonitor()

    private var detailSurface: HerdrAgentDetailSurface {
        switch location {
        case "herdr.agent": .agentWindow
        case "herdr.space": .space(hasAgent: store.uiSpaces[target]?.selectedTab?.agentTab != nil)
        default: .elsewhere
        }
    }

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
        .background(HerdrWindowReader { store.movePage(from: $0, to: $1) })
        .onAppear {
            keyMonitor.active = automaticActions
            keyMonitor.install(store: store) { store, event, window in
                store.performSceneKey(
                    characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags,
                    repeats: event.isARepeat, in: window, surface: detailSurface)
            }
        }
        .onDisappear {
            keyMonitor.active = false
            keyMonitor.remove()
        }
        .onChange(of: automaticActions) { keyMonitor.active = automaticActions }
        .task(id: automaticActions) {
            if automaticActions { await store.watch() } else { store.stopWatching() }
        }
    }
}
