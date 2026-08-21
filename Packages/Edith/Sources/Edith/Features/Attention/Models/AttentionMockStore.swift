import Foundation
import Observation

@MainActor
@Observable
final class AttentionMockStore {
    var selectedSection: AttentionSection = .overview
    var selectedRange: AttentionRange = .month
    var selectedDate: Date
    var selectedSegmentID: UUID?
    var selectedIdentityID: String?
    var selectedInsightID: String?
    var librarySearch = ""
    var libraryKind = "All"
    var timelineFilter = "All activity"
    var insightFilter = "Highlights"
    var musicGrouping = "Tracks"
    var showSetup = false
    var showFocusBuilder = false
    var showCorrection = false
    var showRulePreview = false
    var recordingPaused = false
    var activeFocusTemplateID: String?
    var focusStartedAt: Date?
    var setupStepIndex = 0
    var toast: String?
    var categories: [AttentionCategory]
    var segments: [AttentionSegment]
    var mediaSessions: [AttentionMediaSession]
    var focusSessions: [AttentionFocusSession]
    var identities: [AttentionIdentity]
    var browserProfiles: [AttentionBrowserProfile]
    var focusTemplates: [AttentionFocusTemplate]
    var setupSteps: [AttentionSetupStep]

    let calendar: Calendar
    let firstDate: Date
    let lastDate: Date

    init() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata") ?? .current
        self.calendar = calendar
        firstDate = calendar.date(from: DateComponents(year: 2026, month: 7, day: 23))!
        lastDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 22))!
        selectedDate = lastDate
        categories = Self.makeCategories()
        segments = Self.makeSegments(calendar: calendar, firstDate: firstDate)
        mediaSessions = Self.makeMediaSessions(calendar: calendar, firstDate: firstDate)
        focusSessions = Self.makeFocusSessions(calendar: calendar, firstDate: firstDate)
        identities = []
        browserProfiles = Self.makeBrowserProfiles(lastDate: lastDate)
        focusTemplates = Self.makeFocusTemplates()
        setupSteps = Self.makeSetupSteps()
        identities = Self.makeIdentities(
            segments: segments, categories: categories, lastDate: lastDate)
        selectedSegmentID = daySegments.first?.id
        selectedIdentityID = identities.first?.id
    }

    var allDates: [Date] {
        (0..<31).compactMap { calendar.date(byAdding: .day, value: $0, to: firstDate) }
    }

    var visibleDates: [Date] {
        let available = allDates.filter { $0 <= selectedDate }
        return Array(available.suffix(selectedRange.dayCount))
    }

    var visibleSegments: [AttentionSegment] {
        let dateSet = Set(visibleDates.map { calendar.startOfDay(for: $0) })
        return segments.filter { dateSet.contains(calendar.startOfDay(for: $0.start)) }
    }

    var daySegments: [AttentionSegment] {
        segments.filter { calendar.isDate($0.start, inSameDayAs: selectedDate) }
            .sorted { $0.start < $1.start }
    }

    var selectedSegment: AttentionSegment? {
        guard let selectedSegmentID else { return nil }
        return segments.first { $0.id == selectedSegmentID }
    }

    var selectedIdentity: AttentionIdentity? {
        guard let selectedIdentityID else { return nil }
        return identities.first { $0.id == selectedIdentityID }
    }

    var dailySummaries: [AttentionDailySummary] {
        visibleDates.map(summary(for:))
    }

    var allDailySummaries: [AttentionDailySummary] {
        allDates.map(summary(for:))
    }

    var visibleMedia: [AttentionMediaSession] {
        let dateSet = Set(visibleDates.map { calendar.startOfDay(for: $0) })
        return mediaSessions.filter { dateSet.contains(calendar.startOfDay(for: $0.start)) }
    }

    var visibleFocusSessions: [AttentionFocusSession] {
        let dateSet = Set(visibleDates.map { calendar.startOfDay(for: $0) })
        return focusSessions.filter { dateSet.contains(calendar.startOfDay(for: $0.start)) }
    }

    var filteredIdentities: [AttentionIdentity] {
        identities.filter { identity in
            let matchesSearch =
                librarySearch.isEmpty
                || identity.name.localizedCaseInsensitiveContains(librarySearch)
                || identity.domains.contains { $0.localizedCaseInsensitiveContains(librarySearch) }
                || identity.nativeApplications.contains {
                    $0.localizedCaseInsensitiveContains(librarySearch)
                }
            guard matchesSearch else { return false }
            guard libraryKind != "All" else { return true }
            return category(for: identity.categoryID)?.kind.title == libraryKind
        }
        .sorted { $0.totalSeconds > $1.totalSeconds }
    }

    var insights: [AttentionInsight] {
        let summaries = dailySummaries
        let active = summaries.reduce(0) { $0 + $1.activeSeconds }
        let focus = summaries.reduce(0) { $0 + $1.focusSeconds }
        let distraction = summaries.reduce(0) { $0 + $1.distractingSeconds }
        let automation = summaries.reduce(0) { $0 + $1.automationSeconds }
        let music = summaries.reduce(0) { $0 + $1.musicSeconds }
        let strongest = summaries.max { $0.focusSeconds < $1.focusSeconds }
        let averageRecovery = max(3, Int(17 - min(10, focus / 28_000)))
        return [
            AttentionInsight(
                id: "focus-window", symbol: "sun.max.fill", title: "Your clearest focus window",
                detail:
                    "Deep work is 27% longer between 9:30 AM and noon, based on 24 comparable sessions.",
                value: "+27%", category: "Focus", confidence: 0.93),
            AttentionInsight(
                id: "recovery", symbol: "arrow.uturn.backward.circle.fill",
                title: "Interruptions are getting easier to recover from",
                detail:
                    "Median recovery is \(averageRecovery) minutes, down from 14 minutes at the start of this period.",
                value: "\(averageRecovery)m", category: "Attention", confidence: 0.89),
            AttentionInsight(
                id: "social", symbol: "bubble.left.and.bubble.right.fill",
                title: "Communication creates most short switches",
                detail:
                    "WhatsApp and Slack account for 41% of context changes, but only 18% of active time.",
                value: "41%", category: "Distraction", confidence: 0.96),
            AttentionInsight(
                id: "automation", symbol: "gearshape.2.fill",
                title: "Delegated work returned meaningful time",
                detail:
                    "Agents ran for \(AttentionTime.duration(automation, compact: true)) while your attention moved elsewhere.",
                value: AttentionTime.duration(automation, compact: true), category: "Automation",
                confidence: 0.99),
            AttentionInsight(
                id: "music", symbol: "music.note",
                title: "Instrumental music accompanies longer blocks",
                detail:
                    "Sessions with instrumental playlists were 19% longer across \(visibleMedia.count) listening sessions.",
                value: AttentionTime.duration(music, compact: true), category: "Music",
                confidence: 0.78),
            AttentionInsight(
                id: "entertainment", symbol: "play.rectangle.fill",
                title: "Entertainment stayed inside your evening budget",
                detail:
                    "Foreground entertainment used \(AttentionTime.duration(distraction, compact: true)) across this range.",
                value: "86%", category: "Entertainment", confidence: 0.91),
            AttentionInsight(
                id: "coverage", symbol: "checkmark.seal.fill", title: "Tracking coverage is strong",
                detail:
                    "\(Int(active > 0 ? 96 : 0))% of present time has high-confidence context and profile information.",
                value: "96%", category: "Quality", confidence: 0.98),
            AttentionInsight(
                id: "best-day", symbol: "trophy.fill", title: "Best focus day",
                detail: strongest.map {
                    "\(AttentionTime.day($0.date)) held your longest combined intentional work."
                }
                    ?? "No focus sessions in this range.",
                value: strongest.map { AttentionTime.duration($0.focusSeconds, compact: true) }
                    ?? "0m",
                category: "Focus", confidence: 0.95),
        ]
    }

    var metrics: [AttentionMetric] {
        let summaries = dailySummaries
        let active = summaries.reduce(0) { $0 + $1.activeSeconds }
        let focus = summaries.reduce(0) { $0 + $1.focusSeconds }
        let away = summaries.reduce(0) { $0 + $1.awaySeconds }
        let uncertain = summaries.reduce(0) { $0 + $1.uncertainSeconds }
        return [
            AttentionMetric(
                id: "active", title: "Present",
                value: AttentionTime.duration(active, compact: true),
                detail: "Interactive and passive", symbol: "person.fill.checkmark"),
            AttentionMetric(
                id: "focus", title: "Intentional",
                value: AttentionTime.duration(focus, compact: true),
                detail: active > 0 ? "\(Int(focus / active * 100))% of present time" : "No data",
                symbol: "scope"),
            AttentionMetric(
                id: "away", title: "Away", value: AttentionTime.duration(away, compact: true),
                detail: "Locked, asleep, or idle", symbol: "moon.zzz.fill"),
            AttentionMetric(
                id: "quality", title: "Data quality", value: "96%",
                detail: AttentionTime.duration(uncertain, compact: true) + " uncertain",
                symbol: "checkmark.seal.fill"),
        ]
    }

    var currentSetupStep: AttentionSetupStep { setupSteps[setupStepIndex] }

    func category(for id: String) -> AttentionCategory? {
        categories.first { $0.id == id }
    }

    func summary(for date: Date) -> AttentionDailySummary {
        let daySegments = segments.filter { calendar.isDate($0.start, inSameDayAs: date) }
        let dayMedia = mediaSessions.filter { calendar.isDate($0.start, inSameDayAs: date) }
        let dayFocus = focusSessions.filter { calendar.isDate($0.start, inSameDayAs: date) }
        func seconds(_ presence: AttentionPresence) -> TimeInterval {
            daySegments.filter { $0.presence == presence }.reduce(0) { $0 + $1.duration }
        }
        let distraction = daySegments.filter {
            category(for: $0.categoryID)?.kind == .distracting
        }.reduce(0) { $0 + $1.duration }
        let entertainment = daySegments.filter {
            category(for: $0.categoryID)?.kind == .entertainment
        }.reduce(0) { $0 + $1.duration }
        return AttentionDailySummary(
            date: date,
            activeSeconds: seconds(.active),
            passiveSeconds: seconds(.passive),
            awaySeconds: seconds(.away),
            uncertainSeconds: seconds(.uncertain),
            focusSeconds: dayFocus.reduce(0) { $0 + $1.intendedSeconds },
            distractingSeconds: distraction,
            entertainmentSeconds: entertainment,
            musicSeconds: dayMedia.reduce(0) { $0 + $1.playedSeconds },
            automationSeconds: dayFocus.reduce(0) { $0 + $1.automationSeconds },
            switches: max(0, daySegments.count - 1))
    }

    func selectDate(_ date: Date) {
        selectedDate = calendar.startOfDay(for: date)
        selectedSegmentID = daySegments.first?.id
    }

    func selectSegment(_ segment: AttentionSegment) {
        selectedSegmentID = segment.id
    }

    func correctSelectedSegment(presence: AttentionPresence, categoryID: String) {
        guard let selectedSegmentID,
            let index = segments.firstIndex(where: { $0.id == selectedSegmentID })
        else { return }
        segments[index].presence = presence
        segments[index].categoryID = categoryID
        segments[index].confidence = 1
        showCorrection = false
        toast = "Timeline correction saved"
    }

    func assignCategory(_ categoryID: String, to identityID: String) {
        guard let index = identities.firstIndex(where: { $0.id == identityID }) else { return }
        identities[index].categoryID = categoryID
        identities[index].ruleSource = "User rule"
        for segmentIndex in segments.indices
        where segments[segmentIndex].service == identities[index].name {
            segments[segmentIndex].categoryID = categoryID
        }
        showRulePreview = false
        toast = "Rule applied to current and historical activity"
    }

    func toggleBrowser(_ profileID: UUID) {
        guard let index = browserProfiles.firstIndex(where: { $0.id == profileID }) else { return }
        browserProfiles[index].connected.toggle()
        browserProfiles[index].lastSeen = lastDate
        toast =
            browserProfiles[index].connected
            ? "Browser profile connected" : "Browser profile paused"
    }

    func toggleDeepMode(_ profileID: UUID) {
        guard let index = browserProfiles.firstIndex(where: { $0.id == profileID }) else { return }
        browserProfiles[index].deepMode.toggle()
        toast = browserProfiles[index].deepMode ? "Deep mode enabled" : "Deep mode disabled"
    }

    func beginFocus(_ templateID: String) {
        activeFocusTemplateID = templateID
        focusStartedAt = Date()
        showFocusBuilder = false
        toast = "Focus session started"
    }

    func endFocus() {
        activeFocusTemplateID = nil
        focusStartedAt = nil
        toast = "Focus session completed"
    }

    func advanceSetup() {
        setupSteps[setupStepIndex].completed = true
        if setupStepIndex < setupSteps.count - 1 {
            setupStepIndex += 1
        } else {
            showSetup = false
            toast = "Attention setup complete"
        }
    }

    func resetSetup() {
        setupStepIndex = 0
        for index in setupSteps.indices { setupSteps[index].completed = false }
        showSetup = true
    }

    private static func makeCategories() -> [AttentionCategory] {
        [
            AttentionCategory(
                id: "work-coding", name: "Coding", parent: "Work", kind: .productive,
                symbol: "chevron.left.forwardslash.chevron.right"),
            AttentionCategory(
                id: "work-research", name: "Research", parent: "Work", kind: .productive,
                symbol: "doc.text.magnifyingglass"),
            AttentionCategory(
                id: "work-design", name: "Design", parent: "Work", kind: .productive,
                symbol: "paintbrush.pointed"),
            AttentionCategory(
                id: "communication-work", name: "Work", parent: "Communication", kind: .neutral,
                symbol: "bubble.left.and.bubble.right"),
            AttentionCategory(
                id: "communication-personal", name: "Personal", parent: "Communication",
                kind: .neutral, symbol: "person.2"),
            AttentionCategory(
                id: "admin", name: "Planning and admin", parent: nil, kind: .neutral,
                symbol: "checklist"),
            AttentionCategory(
                id: "entertainment-video", name: "Video", parent: "Entertainment",
                kind: .entertainment, symbol: "play.rectangle"),
            AttentionCategory(
                id: "entertainment-music", name: "Music", parent: "Entertainment",
                kind: .entertainment, symbol: "music.note"),
            AttentionCategory(
                id: "distraction-social", name: "Social feeds", parent: "Distraction",
                kind: .distracting, symbol: "rectangle.stack.badge.play"),
            AttentionCategory(
                id: "uncategorized", name: "Uncategorized", parent: nil, kind: .neutral,
                symbol: "questionmark.square.dashed"),
        ]
    }

    private static func makeSegments(calendar: Calendar, firstDate: Date) -> [AttentionSegment] {
        let templates:
            [(
                Int, Int, String, String, String, String, AttentionPresence, AttentionSurface,
                String?, String?, Double, String?, String?
            )] = [
                (
                    8, 35, "Safari", "Notion", "Daily plan and priorities", "admin", .active, .web,
                    "Safari", "Personal", 0.99, nil, nil
                ),
                (
                    9, 0, "Xcode", "Xcode", "Edith - Attention architecture", "work-coding",
                    .active, .native, nil, nil, 1, "Build Edith Attention", nil
                ),
                (
                    10, 25, "Dia", "GitHub", "Review browser bridge changes", "work-coding",
                    .active, .web, "Dia", "Work", 0.99, "Build Edith Attention", nil
                ),
                (
                    10, 50, "Agent Runner", "Agent Runner", "Implementing browser event schema",
                    "work-coding", .active, .native, nil, nil, 0.96, "Build Edith Attention",
                    "Browser event schema"
                ),
                (
                    11, 20, "WhatsApp", "WhatsApp", "Work conversations", "communication-work",
                    .active, .web, "Dia", "Work", 0.98, "Build Edith Attention", nil
                ),
                (
                    11, 35, "Xcode", "Xcode", "Attention timeline views", "work-coding", .active,
                    .native, nil, nil, 1, "Build Edith Attention", "Browser event schema"
                ),
                (
                    13, 0, "Finder", "Finder", "Lunch break", "admin", .away, .native, nil, nil, 1,
                    nil, nil
                ),
                (
                    14, 5, "Dia", "Figma", "Attention interaction review", "work-design", .active,
                    .web, "Dia", "Work", 0.99, "Design review", nil
                ),
                (
                    15, 15, "Slack", "Slack", "Team check-in", "communication-work", .active,
                    .native, nil, nil, 1, nil, nil
                ),
                (
                    15, 40, "Agent Runner", "Agent Runner", "Running mock data tests",
                    "work-coding", .active, .native, nil, nil, 0.97, "Ship mock", "Mock data tests"
                ),
                (
                    16, 10, "Dia", "Reddit", "Productivity communities", "distraction-social",
                    .active, .web, "Dia", "Personal", 0.99, "Ship mock", nil
                ),
                (
                    16, 30, "Xcode", "Xcode", "Focus session polish", "work-coding", .active,
                    .native, nil, nil, 1, "Ship mock", "Mock data tests"
                ),
                (
                    18, 15, "WhatsApp", "WhatsApp", "Friends and family", "communication-personal",
                    .active, .native, nil, nil, 1, nil, nil
                ),
                (
                    20, 20, "Chrome", "YouTube", "Product design documentary",
                    "entertainment-video", .passive, .web, "Chrome", "Personal", 0.78, nil, nil
                ),
                (
                    21, 35, "Chrome", "YouTube", "Video continued while away",
                    "entertainment-video", .uncertain, .web, "Chrome", "Personal", 0.48, nil, nil
                ),
                (
                    22, 5, "Finder", "Finder", "Mac locked", "admin", .away, .native, nil, nil, 1,
                    nil, nil
                ),
            ]
        let durations = [25, 82, 22, 26, 12, 72, 58, 61, 19, 27, 17, 83, 24, 73, 28, 65]
        var result: [AttentionSegment] = []
        for day in 0..<31 {
            guard let date = calendar.date(byAdding: .day, value: day, to: firstDate) else {
                continue
            }
            let weekday = calendar.component(.weekday, from: date)
            let weekend = weekday == 1 || weekday == 7
            let reducedWeekend = weekend && day != 30
            for (index, template) in templates.enumerated() {
                if reducedWeekend && index > 7 && index < 12 { continue }
                if !weekend && index == 13 && day % 4 != 0 { continue }
                var components = calendar.dateComponents([.year, .month, .day], from: date)
                components.hour = template.0
                components.minute = template.1 + (day * 7 + index * 3) % 8
                guard let start = calendar.date(from: components) else { continue }
                let variation = (day * 11 + index * 7) % 19 - 9
                let minutes = max(7, durations[index] + variation)
                let end = calendar.date(byAdding: .minute, value: minutes, to: start)!
                let service = weekend && template.3 == "GitHub" ? "Readwise Reader" : template.3
                let category = weekend && template.5 == "work-coding" ? "work-research" : template.5
                result.append(
                    AttentionSegment(
                        id: UUID(), start: start, end: end, application: template.2,
                        service: service, title: template.4, categoryID: category,
                        presence: template.6, surface: template.7, browser: template.8,
                        profile: template.9, confidence: template.10,
                        focusSession: reducedWeekend ? nil : template.11,
                        automation: reducedWeekend ? nil : template.12))
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    private static func makeMediaSessions(calendar: Calendar, firstDate: Date)
        -> [AttentionMediaSession]
    {
        let tracks = [
            ("A Walk", "Tycho", "Dive", 318.0),
            ("Weightless", "Marconi Union", "Weightless", 488.0),
            ("We Move Lightly", "Dustin O'Halloran", "Lumiere", 204.0),
            ("Near Light", "Ólafur Arnalds", "Living Room Songs", 228.0),
            ("An Ending", "Brian Eno", "Apollo", 266.0),
            ("Says", "Nils Frahm", "Spaces", 498.0),
            ("Dayvan Cowboy", "Boards of Canada", "The Campfire Headphase", 301.0),
            ("Kerala", "Bonobo", "Migration", 237.0),
        ]
        var result: [AttentionMediaSession] = []
        for day in 0..<31 {
            guard let date = calendar.date(byAdding: .day, value: day, to: firstDate) else {
                continue
            }
            for slot in 0..<3 {
                let track = tracks[(day + slot * 3) % tracks.count]
                var components = calendar.dateComponents([.year, .month, .day], from: date)
                components.hour = [9, 14, 20][slot]
                components.minute = (day * 9 + slot * 11) % 35
                let start = calendar.date(from: components)!
                let repeatCount = slot == 0 ? 5 + day % 4 : 2 + day % 3
                let played = track.3 * Double(repeatCount) * (slot == 2 ? 0.82 : 0.96)
                let end = start.addingTimeInterval(played)
                result.append(
                    AttentionMediaSession(
                        id: UUID(), start: start, end: end,
                        service: slot == 2 && day % 3 == 0 ? "YouTube Music" : "Apple Music",
                        track: track.0, artist: track.1, album: track.2,
                        playedSeconds: played, durationSeconds: track.3 * Double(repeatCount),
                        source: slot == 2 && day % 3 == 0 ? "Dia" : "Music",
                        profile: slot == 2 && day % 3 == 0 ? "Personal" : nil,
                        foreground: slot == 2,
                        completed: played / (track.3 * Double(repeatCount)) > 0.9))
            }
        }
        return result
    }

    private static func makeFocusSessions(calendar: Calendar, firstDate: Date)
        -> [AttentionFocusSession]
    {
        var result: [AttentionFocusSession] = []
        let names = [
            "Build Edith Attention", "Ship mock", "Research browser tracking", "Design review",
        ]
        for day in 0..<31 {
            guard let date = calendar.date(byAdding: .day, value: day, to: firstDate) else {
                continue
            }
            let weekday = calendar.component(.weekday, from: date)
            if (weekday == 1 || weekday == 7) && day != 30 { continue }
            for slot in 0..<2 {
                var components = calendar.dateComponents([.year, .month, .day], from: date)
                components.hour = slot == 0 ? 9 : 15
                components.minute = slot == 0 ? 0 : 35
                let start = calendar.date(from: components)!
                let intended = TimeInterval((68 + (day * 13 + slot * 17) % 47) * 60)
                let offIntent = TimeInterval((4 + (day * 5 + slot * 3) % 16) * 60)
                let end = start.addingTimeInterval(intended + offIntent + 8 * 60)
                result.append(
                    AttentionFocusSession(
                        id: UUID(), start: start, end: end, name: names[(day + slot) % names.count],
                        goal: slot == 0
                            ? "Complete the highest-impact implementation block"
                            : "Review, refine, and ship",
                        intendedSeconds: intended, offIntentSeconds: offIntent,
                        interruptions: 1 + (day + slot) % 4,
                        automationSeconds: TimeInterval((18 + (day * 7 + slot * 11) % 44) * 60)))
            }
        }
        return result
    }

    private static func makeIdentities(
        segments: [AttentionSegment], categories: [AttentionCategory], lastDate: Date
    ) -> [AttentionIdentity] {
        let catalog: [(String, String, [String], [String], String, String)] = [
            ("xcode", "Xcode", ["com.apple.dt.Xcode"], [], "hammer.fill", "work-coding"),
            (
                "github", "GitHub", [], ["github.com"], "chevron.left.forwardslash.chevron.right",
                "work-coding"
            ),
            (
                "agent-runner", "Agent Runner", ["com.example.agentrunner"], [], "sparkles",
                "work-coding"
            ),
            (
                "whatsapp", "WhatsApp", ["net.whatsapp.WhatsApp"], ["web.whatsapp.com"],
                "bubble.left.and.bubble.right.fill", "communication-work"
            ),
            (
                "slack", "Slack", ["com.tinyspeck.slackmacgap"], ["app.slack.com"],
                "number.square.fill", "communication-work"
            ),
            (
                "figma", "Figma", ["com.figma.Desktop"], ["figma.com"], "paintbrush.pointed.fill",
                "work-design"
            ),
            ("notion", "Notion", ["notion.id"], ["notion.so"], "square.text.square.fill", "admin"),
            (
                "youtube", "YouTube", [], ["youtube.com"], "play.rectangle.fill",
                "entertainment-video"
            ),
            (
                "apple-music", "Apple Music", ["com.apple.Music"], ["music.apple.com"],
                "music.note", "entertainment-music"
            ),
            (
                "reddit", "Reddit", [], ["reddit.com"], "bubble.left.circle.fill",
                "distraction-social"
            ),
            (
                "readwise", "Readwise Reader", [], ["read.readwise.io"], "book.pages.fill",
                "work-research"
            ),
            (
                "linear", "Linear", ["com.linear"], ["linear.app"],
                "line.3.horizontal.decrease.circle.fill", "admin"
            ),
            (
                "mail", "Mail", ["com.apple.mail"], ["mail.google.com"], "envelope.fill",
                "communication-work"
            ),
            (
                "spotify", "Spotify", ["com.spotify.client"], ["open.spotify.com"], "waveform",
                "entertainment-music"
            ),
            (
                "news", "Hacker News", [], ["news.ycombinator.com"], "newspaper.fill",
                "uncategorized"
            ),
            (
                "unknown", "Localhost tools", [], ["localhost"], "questionmark.square.dashed",
                "uncategorized"
            ),
        ]
        return catalog.map { item in
            let seconds = segments.filter { $0.service == item.1 }.reduce(0) { $0 + $1.duration }
            return AttentionIdentity(
                id: item.0, name: item.1, symbol: item.4, categoryID: item.5,
                nativeApplications: item.2, domains: item.3,
                totalSeconds: max(seconds, TimeInterval(18_000 + item.1.count * 1_700)),
                lastUsed: lastDate.addingTimeInterval(TimeInterval(-item.1.count * 1_800)),
                ruleSource: item.5 == "uncategorized" ? "No matching rule" : "Built-in mapping")
        }
    }

    private static func makeBrowserProfiles(lastDate: Date) -> [AttentionBrowserProfile] {
        [
            AttentionBrowserProfile(
                id: UUID(), browser: "Dia", profile: "Work", symbol: "globe", connected: true,
                deepMode: true, historyImported: true, lastSeen: lastDate.addingTimeInterval(-42),
                eventCount: 18_492),
            AttentionBrowserProfile(
                id: UUID(), browser: "Dia", profile: "Personal", symbol: "globe", connected: true,
                deepMode: false, historyImported: true, lastSeen: lastDate.addingTimeInterval(-125),
                eventCount: 8_241),
            AttentionBrowserProfile(
                id: UUID(), browser: "Chrome", profile: "Personal", symbol: "network",
                connected: true, deepMode: true, historyImported: true,
                lastSeen: lastDate.addingTimeInterval(-310), eventCount: 6_903),
            AttentionBrowserProfile(
                id: UUID(), browser: "Chrome", profile: "Testing", symbol: "network",
                connected: false, deepMode: false, historyImported: false,
                lastSeen: lastDate.addingTimeInterval(-86_400), eventCount: 0),
            AttentionBrowserProfile(
                id: UUID(), browser: "Safari", profile: "Personal", symbol: "safari",
                connected: true, deepMode: false, historyImported: false,
                lastSeen: lastDate.addingTimeInterval(-1_804), eventCount: 2_118),
        ]
    }

    private static func makeFocusTemplates() -> [AttentionFocusTemplate] {
        [
            AttentionFocusTemplate(
                id: "flow", name: "Deep work", symbol: "scope", durationMinutes: nil,
                allowedCategoryIDs: ["work-coding", "work-research", "work-design"],
                intervention: "Nudge", graceSeconds: 45),
            AttentionFocusTemplate(
                id: "sprint", name: "50 minute sprint", symbol: "timer", durationMinutes: 50,
                allowedCategoryIDs: ["work-coding", "work-design"], intervention: "Observe",
                graceSeconds: 60),
            AttentionFocusTemplate(
                id: "research", name: "Research", symbol: "doc.text.magnifyingglass",
                durationMinutes: 90, allowedCategoryIDs: ["work-research"], intervention: "Nudge",
                graceSeconds: 90),
            AttentionFocusTemplate(
                id: "strict", name: "Distraction block", symbol: "shield.fill", durationMinutes: 30,
                allowedCategoryIDs: ["work-coding"], intervention: "Block", graceSeconds: 15),
        ]
    }

    private static func makeSetupSteps() -> [AttentionSetupStep] {
        [
            AttentionSetupStep(
                id: "welcome", title: "Private by design",
                detail: "Review what Attention stores locally and choose your tracking depth.",
                symbol: "lock.shield.fill", completed: false),
            AttentionSetupStep(
                id: "permissions", title: "macOS signals",
                detail:
                    "Verify application activity, idle time, screen lock, and optional window titles.",
                symbol: "checkmark.shield.fill", completed: false),
            AttentionSetupStep(
                id: "browsers", title: "Browsers and profiles",
                detail: "Pair Dia, Chrome, and Safari profiles without using Terminal.",
                symbol: "globe", completed: false),
            AttentionSetupStep(
                id: "history", title: "Historical context",
                detail: "Choose profiles and date ranges for a clearly labeled estimated import.",
                symbol: "clock.arrow.circlepath", completed: false),
            AttentionSetupStep(
                id: "identity", title: "Services and categories",
                detail: "Approve mappings that unify native applications and websites.",
                symbol: "square.grid.3x3.fill", completed: false),
            AttentionSetupStep(
                id: "music", title: "Music sources",
                detail: "Test Apple Music, Spotify, and browser media metadata.",
                symbol: "music.note", completed: false),
            AttentionSetupStep(
                id: "focus", title: "Focus preferences",
                detail: "Choose focus templates, nudges, and entertainment budgets.",
                symbol: "scope", completed: false),
            AttentionSetupStep(
                id: "backup", title: "Encrypted iCloud backup",
                detail: "Create a recovery key and verify the first local snapshot.",
                symbol: "icloud.and.arrow.up.fill", completed: false),
            AttentionSetupStep(
                id: "calibration", title: "Two-minute calibration",
                detail: "Switch applications, play media, and confirm every signal arrives.",
                symbol: "waveform.path.ecg", completed: false),
        ]
    }
}
