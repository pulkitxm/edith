import AppKit
import EdithKit
import Testing
@testable import EdithHelper

@MainActor
@Suite struct LimitsStatusItemTests {
    @Test func savedAccountNamesRemainStableAcrossEmptyAndPartialStartupSnapshots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = [
            ClaudeAccount(name: "Company", credential: "synthetic-company"),
            ClaudeAccount(name: "Personal", credential: "synthetic-personal"),
        ]
        try await ClaudeAccountStorage(directory: root).save(.init(accounts: accounts))
        let file = root.appendingPathComponent("limits-cache.json")
        let producer = ClaudeAccountLimitsCollector(cacheFile: file)
        let reader = ClaudeAccountLimitsCollector(cacheFile: file)
        let store = UsageStore(accountsDirectory: root, accountLimits: reader)
        defer { store.shutdown() }
        await store.reloadLimitsFromHistory()
        #expect(store.claudeAccounts.map(\.name) == ["Company", "Personal"])
        #expect(store.claudeAccounts.allSatisfy { $0.limits.session == nil })
        _ = await producer.refresh(accounts: accounts) { account, _ in
            .init(
                provider: .claude,
                session: .init(percent: account.name == "Company" ? 12 : 25, resetsAt: nil),
                week: nil)
        }
        await store.receiveLimitsSnapshot(
            .init(
                refreshedAt: Date(),
                providers: [
                    .init(provider: .claude, session: .init(percent: 99, resetsAt: nil), week: nil)
                ], failure: nil))
        #expect(store.claudeAccounts.map(\.id) == accounts.map(\.id))
        #expect(store.claudeAccounts.map { $0.limits.session?.percent } == [12, 25])
        let personal = ClaudeAccountLimits(
            id: accounts[1].id, name: "Stale display name",
            limits: .init(provider: .claude, session: .init(percent: 33, resetsAt: nil), week: nil),
            refreshedAt: Date())
        await store.receiveLimitsSnapshot(
            .init(refreshedAt: Date(), providers: [], failure: nil, claudeAccounts: [personal]))
        #expect(store.claudeAccounts.map(\.name) == ["Company", "Personal"])
        #expect(store.claudeAccounts.map { $0.limits.session?.percent } == [12, 33])
        await store.receiveLimitsSnapshot(.init(refreshedAt: Date(), providers: [], failure: nil))
        #expect(store.claudeAccounts.map { $0.limits.session?.percent } == [12, 33])
        try await ClaudeAccountStorage(directory: root).save(.init(accounts: [accounts[1]]))
        await store.reloadLimitsFromHistory()
        #expect(store.claudeAccounts.map(\.name) == ["Personal"])
    }

    @Test func namedAccountsHonorCustomLabelAndRiskColors() {
        let domain = "test.account-colors." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("custom", forKey: AppStorageKeys.MenuBar.colorMode)
        defaults.set("#FFFFFF", forKey: AppStorageKeys.MenuBar.subColorHex)
        defaults.set("#123456", forKey: AppStorageKeys.MenuBar.lowColorHex)
        defaults.set("#654321", forKey: AppStorageKeys.MenuBar.midColorHex)
        defaults.set("#FEDCBA", forKey: AppStorageKeys.MenuBar.highColorHex)
        defaults.set(false, forKey: AppStorageKeys.General.smartColor)
        let account = ClaudeAccountLimits(
            id: UUID(), name: "Company",
            limits: .init(
                provider: .claude, session: .init(percent: 10, resetsAt: nil),
                week: .init(percent: 95, resetsAt: nil)), refreshedAt: Date())
        let columns = LimitsStatusItem.accountGroups([account], masked: false, defaults: defaults)[
            0
        ].columns
        #expect(columns[0].labelColor == LimitsStatusItem.nsColor(hex: "FFFFFF"))
        #expect(columns[0].valueColor == LimitsStatusItem.nsColor(hex: "123456"))
        #expect(columns[1].valueColor == LimitsStatusItem.nsColor(hex: "FEDCBA"))
        let hidden = LimitsStatusItem.accountGroups([account], masked: true, defaults: defaults)[0]
            .columns
        #expect(hidden.allSatisfy { $0.value == "·" && $0.valueColor == $0.labelColor })
        defaults.set("auto", forKey: AppStorageKeys.MenuBar.colorMode)
        let automatic = LimitsStatusItem.accountGroups(
            [account], masked: false, defaults: defaults)[0].columns
        #expect(automatic[0].labelColor == .secondaryLabelColor)
        #expect(automatic[0].valueColor == .systemGreen)
    }

    @Test func renderNamedAccountCustomColorsWithSyntheticLimits() throws {
        guard let output = ProcessInfo.processInfo.environment["EDITH_ACCOUNT_COLOR_EVIDENCE_DIR"]
        else { return }
        let domain = "test.account-color-render." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("custom", forKey: AppStorageKeys.MenuBar.colorMode)
        defaults.set("FFB8D2", forKey: AppStorageKeys.MenuBar.subColorHex)
        defaults.set("61F5AA", forKey: AppStorageKeys.MenuBar.lowColorHex)
        defaults.set("FFCA5D", forKey: AppStorageKeys.MenuBar.midColorHex)
        defaults.set("FF6D8A", forKey: AppStorageKeys.MenuBar.highColorHex)
        defaults.set(false, forKey: AppStorageKeys.General.smartColor)
        let accounts = [
            ClaudeAccountLimits(
                id: UUID(), name: "Company",
                limits: .init(
                    provider: .claude, session: .init(percent: 12, resetsAt: nil),
                    week: .init(percent: 68, resetsAt: nil)), refreshedAt: Date()),
            ClaudeAccountLimits(
                id: UUID(), name: "Personal",
                limits: .init(
                    provider: .claude, session: .init(percent: 25, resetsAt: nil),
                    week: .init(percent: 95, resetsAt: nil)), refreshedAt: Date()),
        ]
        let view = StackedLimitsView()
        view.groups = LimitsStatusItem.accountGroups(accounts, masked: false, defaults: defaults)
        view.frame = NSRect(x: 12, y: 10, width: view.desiredWidth, height: 24)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: view.desiredWidth + 24, height: 44))
        host.appearance = NSAppearance(named: .darkAqua)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        host.addSubview(view)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let root = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent("account-colors.png"))
    }

    @Test func namedAccountsUseResetTimeForSmartRiskColor() {
        let domain = "test.account-smart-colors." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("custom", forKey: AppStorageKeys.MenuBar.colorMode)
        defaults.set("#123456", forKey: AppStorageKeys.MenuBar.lowColorHex)
        defaults.set("#FEDCBA", forKey: AppStorageKeys.MenuBar.highColorHex)
        defaults.set(true, forKey: AppStorageKeys.General.smartColor)
        let account = ClaudeAccountLimits(
            id: UUID(), name: "Company",
            limits: .init(
                provider: .claude,
                session: .init(percent: 90, resetsAt: Date().addingTimeInterval(5 * 3600)),
                week: nil),
            refreshedAt: Date())
        let smart = LimitsStatusItem.accountGroups([account], masked: false, defaults: defaults)[0]
            .columns
        #expect(smart[0].valueColor == LimitsStatusItem.nsColor(hex: "FEDCBA"))
    }

    @Test func failedWebsiteRefreshCannotReloadTheOldWeeklyZeroIntoTheMenuBar() async throws {
        let url = LimitsHistory.url
        let previous = try? Data(contentsOf: url)
        defer {
            if let previous {
                try? previous.write(to: url)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        var history = LimitsHistory(url: url)
        let appended = history.append(
            provider: .claude, session: nil,
            week: .init(percent: 0, resetsAt: Date().addingTimeInterval(3600)))
        #expect(appended)
        let store = UsageStore()
        defer { store.shutdown() }
        let snapshot = LimitsTopicSnapshot(
            refreshedAt: Date(),
            providers: [
                .init(
                    provider: .claude, session: nil, week: nil,
                    error: "Website session unavailable")
            ], failure: nil)
        await store.receiveLimitsSnapshot(snapshot)
        await store.reloadLimitsFromHistory()
        #expect(store.limits(for: .claude).session == nil)
        #expect(store.limits(for: .claude).week == nil)
        #expect(store.limitsError == "Website session unavailable")
    }

    @Test func resetCountdownFormatsEveryUnitAndRollover() {
        let now = Date(timeIntervalSince1970: 0)
        let cases: [(TimeInterval, String)] = [
            (-1, "0s"), (0, "0s"), (0.1, "1s"), (9, "9s"), (59, "59s"),
            (60, "1m 0s"), (3599, "59m 59s"), (3600, "1h 0m 0s"),
            (86399, "23h 59m 59s"), (86400, "1d 0h 0m 0s"),
            (183845, "2d 3h 4m 5s"),
        ]
        for (interval, expected) in cases {
            #expect(
                MenuCountdown.remaining(until: now.addingTimeInterval(interval), now: now)
                    == expected)
        }
    }

    @Test func menuBarProvidersKeepEveryEnabledSlotReserved() {
        let suite = "menu-bar-provider-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppStorageKeys.Limits.claudeEnabled)
        defaults.set(true, forKey: AppStorageKeys.Limits.codexEnabled)
        let codex = ProviderLimits(
            provider: .codex, session: LimitWindow(percent: 42, resetsAt: nil), week: nil)

        let providers = LimitsStatusItem.stableProviders([codex], defaults: defaults)

        #expect(providers.map(\.provider) == [.claude, .codex, .cursor, .grok])
        #expect(providers[0].isAvailable == false)
        #expect(providers[1].session?.percent == 42)
    }

    @Test func stackedLayoutUsesCurrentValueWidths() {
        let compact = StackedLimitsView()
        compact.groups = [
            .init(
                logo: nil,
                columns: [
                    .init(
                        label: "5h", value: "7", valueColor: .labelColor, labelColor: .labelColor),
                    .init(
                        label: "7d", value: "53", valueColor: .labelColor, labelColor: .labelColor),
                    .init(
                        label: "F", value: "54", valueColor: .labelColor, labelColor: .labelColor),
                ])
        ]
        let maximum = StackedLimitsView()
        maximum.groups = [
            .init(
                logo: nil,
                columns: [
                    .init(
                        label: "5h", value: "100", valueColor: .labelColor, labelColor: .labelColor),
                    .init(
                        label: "7d", value: "100", valueColor: .labelColor, labelColor: .labelColor),
                    .init(
                        label: "F", value: "100", valueColor: .labelColor, labelColor: .labelColor),
                ])
        ]

        #expect(compact.desiredWidth < maximum.desiredWidth)
    }

    @Test func titleSizingIncludesStatusButtonInsets() {
        let title = NSAttributedString(
            string: "100%  100%",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)])

        #expect(StatusItemSizing.titleLength(title) == ceil(title.size().width + 8))
    }

    @Test func retiredStatusItemsCannotKeepMenuBarItemsDisabled() {
        let suite = "limits-status-item-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "NSStatusItem VisibleCC edithGlasses")
        defaults.set(42, forKey: "NSStatusItem Preferred Position edithGlasses")
        defaults.set(false, forKey: "NSStatusItem VisibleCC limits")
        defaults.set(false, forKey: "NSStatusItem VisibleCC systemStats")
        defaults.set(false, forKey: "NSStatusItem VisibleCC systemStats.v2")
        defaults.set(false, forKey: "NSStatusItem VisibleCC micMute.v2")

        removeRetiredStatusItemDefaults(defaults)

        #expect(defaults.object(forKey: "NSStatusItem VisibleCC edithGlasses") == nil)
        #expect(defaults.object(forKey: "NSStatusItem Preferred Position edithGlasses") == nil)
        #expect(defaults.object(forKey: "NSStatusItem VisibleCC limits") == nil)
        #expect(defaults.object(forKey: "NSStatusItem VisibleCC systemStats") == nil)
        #expect(defaults.object(forKey: "NSStatusItem VisibleCC systemStats.v2") == nil)
        #expect(defaults.object(forKey: "NSStatusItem VisibleCC micMute.v2") == nil)
    }

    @Test func legacyFixedTintsBecomeAutomatic() {
        #expect(MenuBarTintMode(preference: nil) == .automatic)
        #expect(MenuBarTintMode(preference: "auto") == .automatic)
        #expect(MenuBarTintMode(preference: "white") == .automatic)
        #expect(MenuBarTintMode(preference: "black") == .automatic)
        #expect(MenuBarTintMode(preference: "custom") == .custom)
        #expect(MenuBarTintMode.automatic.color(custom: .white) == .labelColor)
        #expect(MenuBarTintMode.custom.color(custom: .systemPink) == .systemPink)
        #expect(MenuBarTintMode.custom.color(custom: nil) == .labelColor)
    }

    @Test func lowRiskIsPureGreen() {
        #expect(LimitsStatusItem.color(forRisk: 0.0) == .systemGreen)
        #expect(LimitsStatusItem.color(forRisk: 0.30) == .systemGreen)
    }

    @Test func highRiskIsPureRed() {
        #expect(LimitsStatusItem.color(forRisk: 0.85) == .systemRed)
        #expect(LimitsStatusItem.color(forRisk: 1.0) == .systemRed)
    }

    @Test func midRiskIsInterpolated() {
        let c = LimitsStatusItem.color(forRisk: 0.42)
        #expect(c != .systemGreen)
        #expect(c != .systemRed)
    }

    @Test func riskClamps() {
        #expect(LimitsStatusItem.color(forRisk: -1) == .systemGreen)
        #expect(LimitsStatusItem.color(forRisk: 2) == .systemRed)
    }
}
