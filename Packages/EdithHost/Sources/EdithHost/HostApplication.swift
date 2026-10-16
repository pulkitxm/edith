import AppKit
import EdithHostCore
import EdithExtensionUI
import EdithExtensionSupport
import SwiftUI

struct HostApplication: App {
    @NSApplicationDelegateAdaptor(HostApplicationDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var theme =
        "accent"
    @AppStorage(AppStorageKeys.General.appearance, store: SharedDefaults.store) private
        var appearance = "system"
    @AppStorage(WindowZoom.defaultsKey, store: SharedDefaults.store) private var zoom = 1.0

    private var runtime: HostRuntime { delegate.runtime }

    var body: some Scene {
        WindowGroup("Edith", id: "main") {
            GeometryReader { geometry in
                Group {
                    if let marketplace = runtime.marketplace {
                        HostWorkspace(
                            marketplace: marketplace, presenter: runtime.remotePresenter,
                            updater: runtime.updater,
                            showWelcome: { runtime.coreServices?.showWelcome() },
                            panelShortcutChanged: { runtime.coreServices?.panelShortcutChanged() },
                            additionalSettings: {
                                runtime.coreServices?.settings(
                                    $0, presenter: runtime.remotePresenter)
                            },
                            coreOnline: runtime.coreServices?.online ?? false,
                            coreSummary: runtime.coreServices?.sidebarSummary ?? "Starting",
                            sectionWindows: runtime.sectionWindows,
                            windowNavigation: runtime.windowNavigation,
                            musicSlots: runtime.musicSlots
                        )
                        .environment(\.hostTerminalWindows, runtime.terminalWindows)
                    } else if runtime.startupError {
                        ContentUnavailableView(
                            "Edith could not start", systemImage: "exclamationmark.triangle")
                    } else {
                        Color.clear
                    }
                }
                .environment(\.compactLayout, geometry.size.width < UIScale.pt(720))
                .font(.system(size: UIScale.pt(13)))
                .controlSize(UIScale.controlSize)
                .disclosureGroupStyle(EdithDisclosureGroupStyle())
                .tint(themeColor(theme))
                #if EDITH_GUI_FIXTURE
                .background { HostGUIVisibilityProbe() }
                #endif
                .task {
                    delegate.openMainWindow = { openWindow(id: "main") }
                    runtime.launch()
                    if delegate.launchedAtLogin { delegate.mainWindow()?.close() }
                }
            }
            .tracksWindowVisibility()
            .frame(minWidth: 540, minHeight: 400)
            .onAppear {
                UIScale.apply(zoom); applyAppearance(appearance)
            }
            .onChange(of: zoom) {
                UIScale.apply(zoom); runtime.synchronizeAppearance()
            }
            .onChange(of: appearance) {
                applyAppearance(appearance); runtime.synchronizeAppearance()
            }
            .onChange(of: theme) { runtime.synchronizeAppearance() }
            .onChange(of: runtime.remotePresenter?.cleanupFailed ?? false) {
                if runtime.remotePresenter?.cleanupFailed == true {
                    runtime.remotePresenter?.retryCleanup()
                }
            }
        }
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Edith") { HostQuit.terminate() }.keyboardShortcut("q")
            }
            CommandGroup(replacing: .newItem) {}
        }
        Settings { HostSettingsRedirect() }
    }
}
