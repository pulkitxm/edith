import EdithExtensionSupport
import Foundation

public enum HostSurfaceDemand {
    public static func providerIDs(
        home: SurfaceLayout, notch: SurfaceLayout, notchEnabled: Bool,
        entries: [HostExtension]
    ) -> Set<String> {
        let homeCards = Set(home.visible.map { $0.widget.rawValue })
        let notchCards = notchEnabled ? Set(notch.visible.map { $0.widget.rawValue }) : []
        let tabs =
            notchEnabled
            ? Set(SurfaceNotchTab.allCases.map(\.rawValue)).subtracting(notch.hiddenTabs) : []
        return Set(
            entries.compactMap { entry in
                !homeCards.isDisjoint(with: entry.homeCards)
                    || !notchCards.isDisjoint(with: entry.notchCards)
                    || !tabs.isDisjoint(with: entry.notchTabs) ? entry.id : nil
            })
    }
}
