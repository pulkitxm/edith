import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import Observation
import SwiftUI

struct HostSidebarMaterial: View {
    var body: some View {
        SkeuoSurface()
            .allowsHitTesting(false)
    }
}

struct HostSidebarGlyph: View {
    let page: HostNavigationPage
    var size: CGFloat
    var weight: Font.Weight = .medium

    var body: some View {
        Group {
            if let name = page.logoName, let image = HostSidebarLogo.image(named: name) {
                Image(nsImage: image).resizable().renderingMode(.template).scaledToFit()
            } else {
                Image(systemName: page.symbol).font(.system(size: size, weight: weight))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor enum HostSidebarLogo {
    private static var cache: [String: NSImage] = [:]
    private static let sources = [
        "herdr": #"""
        <svg fill="currentColor" viewBox="100 118 412 412" \#
        xmlns="http://www.w3.org/2000/svg"><g transform="translate(0 512) scale(.1 -.1)" \#
        stroke="none"><path d="M2794 3710 c-129 -33 -299 -135 -359 -214 -21 -28 -26 -42 -21 \#
        -63 9 -38 154 -178 199 -192 32 -11 41 -9 104 23 171 86 354 70 475 -43 150 -138 150 \#
        -379 0 -511 -107 -95 -278 -94 -386 2 l-46 40 -11 -29 c-16 -40 -14 -122 4 -164 60 \#
        -144 264 -222 452 -174 360 92 559 494 430 868 -36 103 -81 173 -175 267 -71 72 -100 \#
        93 -180 132 -52 26 -127 54 -167 62 -96 21 -230 20 -319 -4z M2183 3695 c-116 -32 -221 \#
        -108 -273 -199 -17 -28 -30 -54 -30 -58 0 -4 20 1 45 12 66 28 220 68 294 76 64 7 65 7 \#
        137 83 40 41 71 77 69 79 -2 2 -21 8 -42 13 -55 12 -140 10 -200 -6z M2212 3388 c-159 \#
        -22 -390 -122 -559 -241 -299 -210 -585 -600 -609 -828 -12 -118 40 -251 125 -318 96 \#
        -76 178 -98 426 -116 110 -8 224 -21 254 -29 125 -34 230 -115 272 -211 11 -24 24 -81 \#
        30 -127 20 -170 65 -271 166 -374 34 -35 63 -65 63 -67 0 -1 -10 -27 -22 -57 -29 -76 \#
        -37 -259 -14 -350 42 -170 158 -318 311 -397 44 -23 98 -46 120 -52 22 -6 45 -14 51 \#
        -18 5 -5 15 -48 22 -96 6 -48 14 -92 17 -97 4 -6 415 -10 1131 -10 l1124 0 0 1584 0 \#
        1585 -55 -19 c-84 -29 -143 -68 -232 -154 l-83 -78 -54 49 c-111 102 -233 151 -391 160 \#
        -113 6 -199 -10 -298 -54 l-60 -27 -26 34 c-37 51 -120 134 -127 128 -3 -4 0 -34 7 -67 \#
        17 -89 7 -268 -21 -356 -103 -328 -377 -545 -688 -545 -161 0 -273 41 -373 137 -37 35 \#
        -66 75 -85 116 -79 173 -8 407 124 407 44 0 68 -14 117 -66 74 -78 167 -82 238 -9 60 \#
        62 72 147 33 231 -42 90 -120 130 -238 122 -50 -4 -85 -14 -131 -37 -89 -45 -122 -52 \#
        -176 -40 -92 20 -262 163 -302 253 -11 25 -21 45 -22 45 -1 -1 -30 -6 -65 -11z m-256 \#
        -505 c115 -88 129 -102 132 -131 2 -18 -2 -40 -9 -49 -7 -8 -69 -55 -138 -105 -103 -73 \#
        -130 -88 -151 -83 -35 8 -51 34 -48 74 3 31 12 42 83 92 44 31 80 61 82 66 1 4 -30 31 \#
        -69 58 -39 28 -77 56 -85 63 -18 19 -16 72 4 94 32 35 63 23 199 -79z m528 -88 c23 -24 \#
        28 -52 14 -82 l-13 -28 -141 -3 c-130 -2 -142 -1 -158 17 -23 26 -24 66 -1 91 16 18 32 \#
        20 151 20 105 0 136 -3 148 -15z"/></g></svg>
        """#
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
        case "dashboard":
            HostSidebarBadgeFormat.limits(session: sessionPercent, weekly: weeklyPercent)
        default: nil
        }
    }

    func badge(sectionID: String, of parent: String) -> HostSidebarBadge? {
        guard parent == "appMaintenance" else { return nil }
        switch sectionID {
        case "Updates": return HostSidebarBadgeFormat.count(updatesAvailable)
        case "Cleaner": return HostSidebarBadgeFormat.space(reclaimable)
        default: return nil
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
