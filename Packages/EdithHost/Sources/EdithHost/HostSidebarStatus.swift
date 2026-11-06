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
