import EdithExtensionSupport
import Foundation

public enum HostSurfaceDemand {
    public static func providerIDs(
        home: SurfaceLayout, notch: SurfaceLayout, notchEnabled: Bool
    ) -> Set<String> {
        let homeIDs = home.visible.reduce(into: Set<String>()) {
            $0.formUnion($1.widget.providerIDs)
        }
        guard notchEnabled else { return homeIDs }
        let tiles = notch.visible.reduce(into: homeIDs) { $0.formUnion($1.widget.providerIDs) }
        return SurfaceNotchTab.allCases.filter { !notch.hiddenTabs.contains($0.rawValue) }
            .reduce(into: tiles) { $0.formUnion($1.providerIDs) }
    }
}
