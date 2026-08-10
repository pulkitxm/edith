import Adwaita
import EdithCore

struct MainWindowView: View {
    @State private var selection = NavigationDestination.home.id
    @State private var sidebarVisible = true

    private var destination: NavigationDestination { .resolve(selection) }

    var view: Body {
        OverlaySplitView(visible: $sidebarVisible) {
            sidebar
        } content: {
            ViewStack(element: destination) { destination in
                page(for: destination)
                    .topToolbar {
                        HeaderBar {
                            Toggle(icon: .default(icon: .sidebarShow), isOn: $sidebarVisible)
                                .tooltip("Toggle Sidebar")
                        } end: {
                            Text("")
                        }
                        .headerBarTitle {
                            WindowTitle(subtitle: "Edith", title: destination.title)
                        }
                    }
            }
        }
    }

    private var sidebar: View {
        ScrollView {
            List(NavigationDestination.allCases, selection: $selection) { item in
                ActionRow(item.title)
                    .iconName(item.freedesktopIconName)
            }
            .sidebarStyle()
        }
        .topToolbar {
            HeaderBar.empty()
                .headerBarTitle {
                    WindowTitle(subtitle: "for Ubuntu", title: "Edith")
                }
        }
    }

    private func page(for destination: NavigationDestination) -> View {
        switch destination {
        case .home:
            return HomePage()
        case .extensions:
            return ExtensionsPage()
        case .system:
            return CapabilitiesPage()
        case .about:
            return AboutPage()
        default:
            return PortStatusPage(destination: destination)
        }
    }
}
