import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import Observation
import SwiftUI

struct HostSidebarMaterial: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                DashSkin.paper(scheme == .dark)
            } else {
                HostSidebarVisualEffect()
            }
        }
        .overlay(alignment: .trailing) {
            DashSkin.line(scheme == .dark).frame(width: UIScale.pt(1))
        }
        .allowsHitTesting(false)
    }
}

private struct HostSidebarVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct HostSidebarGlyph: View {
    let page: HostNavigationPage
    var size: CGFloat
    var weight: Font.Weight = .medium

    var body: some View {
        EdithIconView(page.icon).font(.system(size: size, weight: weight))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

@MainActor enum HostSidebarLogo {
    private static var cache: [String: NSImage] = [:]
    private static let sources = [
        "claude": #"""
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill="currentColor" \#
        d="m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729\#
        -2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.51\#
        79.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6\#
        .973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.\#
        8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.07\#
        28-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674\#
        -.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 \#
        3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.07\#
        89-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021\#
        -.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.43\#
        11h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729\#
        .1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1\#
        .967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0\#
        175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.327\#
        9h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.048\#
        6-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807\#
        -.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.\#
        674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-\#
        1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.\#
        8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-\#
        .0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064\#
        -1.3114Z"/></svg>
        """#,
        "codex": #"""
        <svg viewBox="0 0 64 64" xmlns="http://www.w3.org/2000/svg"><mask id="codex-cutout"><p\#
        ath fill="white" d="M27.3 0C18.9 0 12 5 10.8 12C4.5 13.8 0 19.2 0 27.5c0 4.8 1.8 9 4.8\#
         11.9-1.6 7.3 2 14.6 8.2 17.9 3.7 2.1 7.9 3 11.7 1.9 3.9 4.3 10.3 5.8 15.8 3.6 5.6-2.2\#
         9.3-6.3 11.4-10.8C59 50.4 64 44.2 64 36.8c0-4.9-1.9-9.1-4.8-12 1.4-7-2.5-14.3-8.7-17.\#
        8-3.4-2-7.3-3.3-11.2-2.2C36.2 1.8 31.9 0 27.3 0Z"/><path fill="none" stroke="black" st\#
        roke-linecap="round" stroke-linejoin="round" stroke-width="4.6" d="m17.5 23.3 5.1 9-5.\#
        1 8.7M34.1 41.1h12.7"/></mask><rect width="64" height="64" fill="currentColor" mask="u\#
        rl(#codex-cutout)"/></svg>
        """#,
        "cursor": #"""
        <svg fill="currentColor" fill-rule="evenodd" viewBox="0 0 24 24" xmlns="http://www.w3.\#
        org/2000/svg"><path d="M22.106 5.68L12.5.135a.998.998 0 00-.998 0L1.893 5.68a.84.84 0 \#
        00-.419.726v11.186c0 .3.16.577.42.727l9.607 5.547a.999.999 0 00.998 0l9.608-5.547a.84.\#
        84 0 00.42-.727V6.407a.84.84 0 00-.42-.726zm-.603 1.176L12.228 22.92c-.063.108-.228.06\#
        4-.228-.061V12.34a.59.59 0 00-.295-.51l-9.11-5.26c-.107-.062-.063-.228.062-.228h18.55c\#
        .264 0 .428.286.296.514z"></path></svg>
        """#,
    ]

    static func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let source = sources[name], let image = NSImage(data: Data(source.utf8)) else {
            return nil
        }
        image.isTemplate = true
        cache[name] = image
        return image
    }
}

struct HostSidebarBadge: Equatable {
    enum Tone: Equatable {
        case neutral
        case accent
        case warning
    }

    let text: String
    let tone: Tone

    init(_ text: String, tone: Tone = .neutral) {
        self.text = text
        self.tone = tone
    }
}

enum HostSidebarBadgeFormat {
    static func sessions(working: Int) -> HostSidebarBadge? {
        guard working > 0 else { return nil }
        return HostSidebarBadge("\(working) working", tone: .accent)
    }

    static func limits(session: Double?, weekly: Double?) -> HostSidebarBadge? {
        let parts = [session, weekly].compactMap { value -> String? in
            guard let value else { return nil }
            return "\(Int(value.rounded()))%"
        }
        guard !parts.isEmpty else { return nil }
        let highest = [session, weekly].compactMap { $0 }.max() ?? 0
        return HostSidebarBadge(
            parts.joined(separator: " · "), tone: highest >= 80 ? .warning : .neutral)
    }

    static func count(_ value: Int) -> HostSidebarBadge? {
        guard value > 0 else { return nil }
        return HostSidebarBadge(String(value), tone: .accent)
    }

    static func space(_ value: String?) -> HostSidebarBadge? {
        guard let value, !value.isEmpty else { return nil }
        return HostSidebarBadge(value)
    }
}

struct HostSidebarBadgeLabel: View {
    let badge: HostSidebarBadge
    let theme: Color

    private var tint: Color {
        switch badge.tone {
        case .neutral: .secondary
        case .accent: theme
        case .warning: .orange
        }
    }

    var body: some View {
        Text(badge.text)
            .font(.system(size: UIScale.pt(10.5), weight: .medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize()
    }
}

@MainActor
@Observable
final class HostSidebarStatusModel {
    private(set) var sessionsWorking = 0
    private(set) var sessionPercent: Double?
    private(set) var weeklyPercent: Double?
    private(set) var updatesAvailable = 0
    private(set) var reclaimable: String?

    func refresh(marketplace: HostMarketplace, defaults: UserDefaults) async {
        let versions = marketplace.sessions.versions.filter {
            marketplace.surfaceAvailability.activeIDs.contains($0.key)
        }
        let provider =
            defaults.string(forKey: AppStorageKeys.Limits.provider).flatMap {
                $0.isEmpty ? nil : $0
            }
            ?? "claude"
        let herdr = await snapshot(marketplace, versions, "herdr", SurfaceTile(.agents))
        guard !Task.isCancelled else { return }
        assign(\.sessionsWorking, herdr.flatMap { Self.count($0, "running") } ?? 0)
        var limitsTile = SurfaceTile(.limits)
        limitsTile.sourceIDs = [provider]
        let usage = await snapshot(marketplace, versions, "usage", limitsTile)
        guard !Task.isCancelled else { return }
        assign(\.sessionPercent, usage.flatMap { Self.percent($0, provider + ":session") })
        assign(\.weeklyPercent, usage.flatMap { Self.percent($0, provider + ":week") })
        let maintenance = await snapshot(
            marketplace, versions, "appMaintenance", SurfaceTile(.ability("appMaintenance")))
        guard !Task.isCancelled else { return }
        assign(\.updatesAvailable, maintenance.flatMap { Self.count($0, "updates") } ?? 0)
        let cleaner = await snapshot(
            marketplace, versions, "cleaner", SurfaceTile(.ability("cleaner")))
        guard !Task.isCancelled else { return }
        assign(\.reclaimable, cleaner?.metrics.first { $0.id == "space" }?.value)
    }

    func badge(pageID: String) -> HostSidebarBadge? {
        switch pageID {
        case "herdr": HostSidebarBadgeFormat.sessions(working: sessionsWorking)
        case "usage":
            HostSidebarBadgeFormat.limits(session: sessionPercent, weekly: weeklyPercent)
        case "appMaintenance": HostSidebarBadgeFormat.count(updatesAvailable)
        case "cleaner": HostSidebarBadgeFormat.space(reclaimable)
        default: nil
        }
    }

    private func snapshot(
        _ marketplace: HostMarketplace, _ versions: [String: String], _ id: String,
        _ tile: SurfaceTile
    ) async -> SurfaceSnapshot? {
        guard versions[id] != nil else { return nil }
        return try? await marketplace.surfaces.requests.snapshot(
            providerID: id, target: .home, tile: tile)
    }

    private static func count(_ snapshot: SurfaceSnapshot, _ metric: String) -> Int? {
        snapshot.metrics.first { $0.id == metric }.flatMap { Int($0.value) }
    }

    private static func percent(_ snapshot: SurfaceSnapshot, _ row: String) -> Double? {
        snapshot.rows.first { $0.id == row }?.progress.map { $0 * 100 }
    }

    private func assign<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<HostSidebarStatusModel, Value>, _ value: Value
    ) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
    }
}
