import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostIntroductions {
    let defaults: UserDefaults

    var enabled: Bool {
        get {
            defaults.object(forKey: HostSettingsCatalog.introductionsEnabledKey) as? Bool ?? true
        }
        nonmutating set {
            defaults.set(newValue, forKey: HostSettingsCatalog.introductionsEnabledKey)
        }
    }

    var seen: Set<String> {
        get { Self.decode(defaults.string(forKey: HostSettingsCatalog.introductionsSeenKey) ?? "") }
        nonmutating set {
            defaults.set(Self.encode(newValue), forKey: HostSettingsCatalog.introductionsSeenKey)
        }
    }

    static func decode(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map(String.init))
    }

    static func encode(_ ids: Set<String>) -> String { ids.sorted().joined(separator: ",") }

    static func shouldPresent(id: String, hasGuide: Bool, enabled: Bool, seen: String) -> Bool {
        hasGuide && enabled && !decode(seen).contains(id)
    }

    func shouldPresent(_ entry: HostExtension?) -> Bool {
        guard let entry else { return false }
        return Self.shouldPresent(
            id: entry.id, hasGuide: entry.guide != nil, enabled: enabled,
            seen: Self.encode(seen))
    }

    func markSeen(_ id: String) { seen = seen.union([id]) }

    func skipAll(current id: String) {
        markSeen(id)
        enabled = false
    }

    func reset() {
        defaults.removeObject(forKey: HostSettingsCatalog.introductionsSeenKey)
        defaults.removeObject(forKey: HostSettingsCatalog.getStartedDismissedKey)
        enabled = true
    }
}

struct HostIntroducedPage<Content: View>: View {
    let entry: HostExtension?
    let defaults: UserDefaults
    let showsReopen: Bool
    let content: () -> Content
    @AppStorage(HostSettingsCatalog.introductionsEnabledKey, store: SharedDefaults.store)
    private var enabled = true
    @AppStorage(HostSettingsCatalog.introductionsSeenKey, store: SharedDefaults.store)
    private var seen = ""
    @State private var reopened = false

    init(
        entry: HostExtension?, defaults: UserDefaults, showsReopen: Bool,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.entry = entry; self.defaults = defaults; self.showsReopen = showsReopen
        self.content = content
        _enabled = AppStorage(
            wrappedValue: true, HostSettingsCatalog.introductionsEnabledKey, store: defaults)
        _seen = AppStorage(
            wrappedValue: "", HostSettingsCatalog.introductionsSeenKey, store: defaults)
    }

    private var presenting: Bool {
        guard let entry, entry.guide != nil else { return false }
        return reopened
            || HostIntroductions.shouldPresent(
                id: entry.id, hasGuide: true, enabled: enabled, seen: seen)
    }

    var body: some View {
        Group {
            if presenting, let entry, let guide = entry.guide {
                intro(entry, guide)
                    .defaultScrollAnchor(.top)
            } else {
                content()
                    .environment(\.pageGuide, guide)
                    .onAppear {
                        defaults.set(true, forKey: HostSettingsCatalog.getStartedTriedKey)
                    }
            }
        }
    }

    private var guide: PageGuideAction? {
        guard showsReopen, let entry, entry.guide != nil else { return nil }
        return PageGuideAction(id: entry.id, title: entry.title) { [reopened = $reopened] in
            reopened.wrappedValue = true
        }
    }

    private func intro(_ entry: HostExtension, _ guide: HostExtensionGuide) -> some View {
        PageIntro(
            extensionID: entry.id, icon: entry.icon, title: entry.title,
            tagline: guide.tagline, summary: guide.summary,
            steps: guide.steps.map {
                PageGuideStep(icon: $0.icon, title: $0.title, detail: $0.detail)
            },
            examples: guide.examples,
            start: PageAction("Get started", icon: .arrowRight) { finish(entry) },
            skipAll: PageAction("Skip all introductions") {
                HostIntroductions(defaults: defaults).skipAll(current: entry.id)
                reopened = false
            })
    }

    private func finish(_ entry: HostExtension) {
        HostIntroductions(defaults: defaults).markSeen(entry.id)
        reopened = false
    }
}

enum HostTitlebarMetrics {
    static let stripHeight = 41.0
    static let rowHeight = 31.0
}
