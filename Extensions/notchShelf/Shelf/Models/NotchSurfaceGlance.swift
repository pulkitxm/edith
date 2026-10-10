import CoreGraphics
import EdithExtensionSupport
import Foundation

struct NotchSurfaceGlance: Equatable, Codable, Sendable {
    let source: SurfaceGlanceSource
    let title: String
    let value: String
    let icon: String
    let urgent: Bool

    var tab: SurfaceNotchTab {
        switch source {
        case .files: .files
        case .workingAgents, .waitingAgents, .stuckAgents, .activeAgents, .quietAgents,
            .failedAgents, .permissions:
            .agents
        default: .home
        }
    }
}

extension NotchShelfController {
    var musicGlancesEnabled: Bool {
        context.defaults.object(forKey: AppStorageKeys.Notch.shelfShowMusic) as? Bool ?? true
    }

    var glanceProviderIDs: Set<String> {
        let sources = [surfaceLayout.notchLeadingGlance, surfaceLayout.notchTrailingGlance]
        if sources.contains(.automatic) {
            var providers: Set<String> = ["herdr", "attention", "usage", "calendar"]
            if musicGlancesEnabled { providers.insert("music") }
            return providers
        }
        var providers = Set(
            sources.compactMap { source in
                switch source {
                case .music: "music"
                case .focus: "attention"
                case .limits: "usage"
                case .nextMeeting: "calendar"
                case .workingAgents, .waitingAgents, .stuckAgents, .activeAgents, .quietAgents,
                    .failedAgents, .permissions:
                    "herdr"
                default: nil
                }
            })
        if surfaceLayout.notchExpandPermissions || surfaceLayout.notchPrioritizePermissions {
            providers.insert("herdr")
        }
        if !musicGlancesEnabled { providers.remove("music") }
        return providers
    }

    static func glanceWidget(_ id: String) -> SurfaceWidget {
        switch id {
        case "herdr": .agents
        case "music": .music
        case "calendar": .calendar
        case "usage": .limits
        case "attention": .focus
        default: .ability(id)
        }
    }

    var leadingGlance: NotchSurfaceGlance? {
        glance(surfaceLayout.notchLeadingGlance, trailing: false)
    }
    var trailingGlance: NotchSurfaceGlance? {
        glance(surfaceLayout.notchTrailingGlance, trailing: true)
    }
    var glanceWingWidth: CGFloat {
        leadingGlance == nil && trailingGlance == nil ? 0 : CGFloat(surfaceLayout.notchWingWidth)
    }

    func openGlance(_ value: NotchSurfaceGlance, on displayID: CGDirectDisplayID) {
        expand(on: displayID, preferredTab: value.tab)
    }

    private func glance(_ source: SurfaceGlanceSource, trailing: Bool) -> NotchSurfaceGlance? {
        if source == .automatic {
            let choices: [SurfaceGlanceSource] =
                trailing
                ? [.nextMeeting, .limits, .files, .clock]
                : [.permissions, .waitingAgents, .music, .workingAgents, .focus, .files]
            return choices.lazy.compactMap { self.glance($0, trailing: trailing) }.first
        }
        if source == .none || (source == .music && !musicGlancesEnabled) { return nil }
        if source == .clock {
            return NotchSurfaceGlance(
                source: source, title: "Local time",
                value: Date().formatted(date: .omitted, time: .shortened), icon: "clock",
                urgent: false)
        }
        if source == .files {
            guard !items.isEmpty, !privacy.hides(.ability("notchShelf")) else { return nil }
            return NotchSurfaceGlance(
                source: source, title: "Shelf files", value: String(items.count),
                icon: "tray.full.fill", urgent: false)
        }
        let pair: (String, SurfaceWidget)
        switch source {
        case .music: pair = ("music", .music)
        case .focus: pair = ("attention", .focus)
        case .limits: pair = ("usage", .limits)
        case .nextMeeting: pair = ("calendar", .calendar)
        default: pair = ("herdr", .agents)
        }
        guard activeIDs.contains(pair.0), !privacy.hides(pair.1),
            let snapshot = surfaceSnapshots[pair.0]
        else { return nil }
        let metricID: String
        switch source {
        case .permissions: metricID = "permissions"
        case .waitingAgents: metricID = "waiting"
        case .stuckAgents: metricID = "stuck"
        case .quietAgents: metricID = "quiet"
        case .failedAgents: metricID = "errors"
        case .workingAgents: metricID = "running"
        default: metricID = "total"
        }
        let metric =
            snapshot.metrics.first { $0.id == metricID }
            ?? (pair.0 == "herdr" ? nil : snapshot.metrics.first)
        if pair.0 == "herdr" {
            guard let count = metric?.value, let number = Int(count), number > 0 else { return nil }
        }
        let value = [metric?.value, snapshot.rows.first?.value, snapshot.rows.first?.title]
            .compactMap { $0 }.first { !$0.isEmpty }
        guard let value, value != "0" else { return nil }
        return NotchSurfaceGlance(
            source: source, title: source.title, value: String(value.prefix(16)), icon: pair.1.icon,
            urgent: [.permissions, .waitingAgents, .stuckAgents, .failedAgents].contains(source))
    }
}
