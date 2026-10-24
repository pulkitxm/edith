import CoreGraphics
import EdithExtensionSupport
import Foundation

struct NotchSurfaceGlance: Equatable, Codable, Sendable {
    let source: SurfaceGlanceSource
    let icon: String
    let value: String
    let detail: String
    let urgency: Int

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

struct NotchGlanceFocus: Equatable, Sendable {
    var name: String
    var endsAt: Date
}

struct NotchGlanceContext: Sendable {
    var working = 0
    var waiting = 0
    var stuck = 0
    var active = 0
    var quiet = 0
    var errors = 0
    var approvals = 0
    var observing = false
    var monitoringStalls = false
    var hasMusic = false
    var playingMusic = false
    var files = 0
    var now = Date()
    var focus: NotchGlanceFocus?
    var quotaRemaining: Double?
    var nextMeeting: Date?

    func resolve(_ source: SurfaceGlanceSource, leading: Bool) -> NotchSurfaceGlance? {
        let selected: SurfaceGlanceSource
        if source == .automatic {
            if approvals > 0 || active > 0 {
                if leading {
                    selected = working > 0 ? .workingAgents : .activeAgents
                } else if approvals > 0 {
                    selected = .permissions
                } else if waiting > 0 {
                    selected = .waitingAgents
                } else if stuck > 0 {
                    selected = .stuckAgents
                } else if errors > 0 {
                    selected = .failedAgents
                } else if quiet > 0 {
                    selected = .quietAgents
                } else {
                    selected = hasMusic ? .music : .activeAgents
                }
            } else if hasMusic {
                selected = .music
            } else if focus != nil {
                selected = leading ? .focus : .clock
            } else if files > 0 {
                selected = leading ? .files : .clock
            } else {
                return nil
            }
        } else {
            selected = source
        }
        switch selected {
        case .none, .automatic: return nil
        case .workingAgents:
            return count(selected, "terminal.fill", working, "Working agents", enabled: observing)
        case .waitingAgents:
            return count(
                selected, "hand.raised.fill", waiting, "Agents need your input",
                enabled: observing, urgency: waiting > 0 ? 1 : 0)
        case .stuckAgents:
            return count(
                selected, "exclamationmark.triangle.fill", stuck, "Confirmed stalled agents",
                enabled: monitoringStalls, urgency: stuck > 0 ? 2 : 0)
        case .activeAgents:
            return count(
                selected, "square.stack.3d.up.fill", active, "Active sessions", enabled: observing)
        case .quietAgents:
            return count(
                selected, "antenna.radiowaves.left.and.right.slash", quiet,
                "Agents with no recent signal", enabled: observing)
        case .failedAgents:
            return count(
                selected, "exclamationmark.circle.fill", errors, "Agent errors",
                enabled: observing, urgency: errors > 0 ? 2 : 0)
        case .permissions:
            return count(
                selected, "hand.raised.fill", approvals, "One-use permission requests",
                enabled: observing, urgency: approvals == 0 ? 0 : 1)
        case .music:
            guard hasMusic else { return nil }
            return NotchSurfaceGlance(
                source: selected, icon: playingMusic ? "waveform" : "pause.fill", value: "",
                detail: "Now playing", urgency: 0)
        case .files:
            return NotchSurfaceGlance(
                source: selected, icon: "tray.full.fill", value: String(files),
                detail: "Shelf files", urgency: 0)
        case .clock:
            return NotchSurfaceGlance(
                source: selected, icon: "clock", value: now.formatted(.dateTime.hour().minute()),
                detail: "Local time", urgency: 0)
        case .focus:
            let remaining = focus.map { max(0, $0.endsAt.timeIntervalSince(now)) }
            return NotchSurfaceGlance(
                source: selected, icon: "timer",
                value: remaining.map { Self.minutes($0) } ?? "Idle",
                detail: focus?.name ?? "Focus timer", urgency: remaining == 0 ? 1 : 0)
        case .limits:
            return NotchSurfaceGlance(
                source: selected, icon: "gauge",
                value: quotaRemaining.flatMap {
                    $0.isFinite ? "\(Int(max(0, min(100, $0))))%" : nil
                } ?? "?", detail: "Lowest remaining quota",
                urgency: (quotaRemaining ?? 100) <= 10 ? 1 : 0)
        case .nextMeeting:
            return NotchSurfaceGlance(
                source: selected, icon: "calendar",
                value: nextMeeting.map { Self.minutes(max(0, $0.timeIntervalSince(now))) }
                    ?? "Free", detail: "Next meeting", urgency: 0)
        }
    }

    private func count(
        _ source: SurfaceGlanceSource, _ icon: String, _ value: Int, _ detail: String,
        enabled: Bool, urgency: Int = 0
    ) -> NotchSurfaceGlance {
        NotchSurfaceGlance(
            source: source, icon: icon, value: enabled ? String(value) : "Off", detail: detail,
            urgency: urgency)
    }

    private static func minutes(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "?" }
        let total = Int(seconds)
        if total >= 3600 { return CompactDuration.detailed(Double(total), showsSeconds: false) }
        return "\(total / 60):\(String(format: "%02d", total % 60))"
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
        providers.insert("herdr")
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

    var nowPlaying: Bool { glanceContext.hasMusic }
    var pendingPermissions: Int { Int(glanceFacts("herdr")?["permissions"] ?? 0) }

    var glanceContext: NotchGlanceContext {
        var context = NotchGlanceContext()
        context.now = glanceNow
        context.files = privacy.hides(.ability("notchShelf")) ? 0 : items.count
        if let facts = glanceFacts("herdr") {
            func value(_ key: String) -> Int { Int(facts[key] ?? 0) }
            context.working = value("working")
            context.waiting = value("waiting")
            context.stuck = value("stuck")
            context.active = value("active")
            context.quiet = value("quiet")
            context.errors = value("errors")
            context.approvals = value("permissions")
            context.observing = true
            context.monitoringStalls = facts["monitoringStalls"] == 1
        }
        if let facts = glanceFacts("music"), musicGlancesEnabled {
            context.hasMusic = facts["hasTrack"] == 1
            context.playingMusic = facts["playing"] == 1
        }
        if let snapshot = surfaceSnapshots["attention"], glanceFacts("attention") != nil,
            let ends = snapshot.facts?["focusEndsAt"]
        {
            context.focus = NotchGlanceFocus(
                name: snapshot.rows.first?.title ?? "Focus",
                endsAt: Date(timeIntervalSince1970: ends))
        }
        context.quotaRemaining = glanceFacts("usage")?["lowestRemaining"]
        context.nextMeeting = glanceFacts("calendar")?["nextMeetingStart"].map {
            Date(timeIntervalSince1970: $0)
        }
        return context
    }

    private func glanceFacts(_ id: String) -> [String: Double]? {
        guard activeIDs.contains(id), !privacy.hides(Self.glanceWidget(id)),
            let snapshot = surfaceSnapshots[id]
        else { return nil }
        return snapshot.facts ?? [:]
    }

    private func glance(_ source: SurfaceGlanceSource, leading: Bool) -> NotchSurfaceGlance? {
        let providerBacked: [SurfaceGlanceSource: String] = [
            .music: "music", .focus: "attention", .limits: "usage", .nextMeeting: "calendar",
            .workingAgents: "herdr", .waitingAgents: "herdr", .stuckAgents: "herdr",
            .activeAgents: "herdr", .quietAgents: "herdr", .failedAgents: "herdr",
            .permissions: "herdr",
        ]
        if let id = providerBacked[source], glanceFacts(id) == nil { return nil }
        if source == .files, privacy.hides(.ability("notchShelf")) { return nil }
        if source == .music, !musicGlancesEnabled { return nil }
        return glanceContext.resolve(source, leading: leading)
    }

    var leadingGlance: NotchSurfaceGlance? {
        glance(surfaceLayout.notchLeadingGlance, leading: true)
    }
    var trailingGlance: NotchSurfaceGlance? {
        glance(surfaceLayout.notchTrailingGlance, leading: false)
    }
    var glanceWingWidth: CGFloat {
        leadingGlance == nil && trailingGlance == nil ? 0 : CGFloat(surfaceLayout.notchWingWidth)
    }

    func openGlance(_ value: NotchSurfaceGlance, on displayID: CGDirectDisplayID) {
        expand(on: displayID, preferredTab: value.tab)
    }
}
