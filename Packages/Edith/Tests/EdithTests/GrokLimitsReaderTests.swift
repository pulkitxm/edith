import Foundation
import Testing

@testable import EdithKit

@Suite struct GrokLimitsReaderTests {
    @Test func weeklyAllowanceKeepsTheProductSplitAndExtraBalances() throws {
        let data = Data(
            """
            {
              "config": {
                "currentPeriod": {
                  "type": "USAGE_PERIOD_TYPE_WEEKLY",
                  "end": "2026-09-26T20:00:25.296578+00:00"
                },
                "creditUsagePercent": 38,
                "onDemandCap": { "val": 20 },
                "onDemandUsed": { "val": 1.5 },
                "productUsage": [
                  { "product": "GrokBuild", "usagePercent": 30 },
                  { "product": "Chat", "usagePercent": 8 }
                ],
                "prepaidBalance": { "val": 5 },
                "billingPeriodEnd": "2026-09-26T20:00:25.296578+00:00"
              }
            }
            """.utf8)
        let limits = try GrokLimitsReader.limits(json: data, tier: "X Premium+")
        #expect(limits.provider == .grok)
        #expect(limits.session == nil)
        #expect(limits.week?.percent == 38)
        #expect(limits.week?.period == "weekly")
        #expect(limits.week?.resetsAt == EdithDate.parseISO("2026-09-26T20:00:25.296578+00:00"))
        let allowance = try #require(limits.grok)
        #expect(allowance.period == "weekly")
        #expect(allowance.tier == "X Premium+")
        #expect(allowance.products.map(\.name) == ["Build", "Chat"])
        #expect(allowance.products.map(\.percent) == [30, 8])
        #expect(allowance.onDemandCap == 20)
        #expect(allowance.onDemandUsed == 1.5)
        #expect(allowance.prepaidBalance == 5)
        #expect(allowance.summary == "X Premium+ · Build 30% · Chat 8%")
        #expect(allowance.extraLine == "Extra credits $5.00, Pay as you go $1.50 of $20.00")
        #expect(GrokPeriod.mark(allowance.period) == "Wk")
        #expect(GrokPeriod.title(allowance.period) == "Weekly allowance")
    }

    @Test func aMonthlyPoolUsesTheMonthlyWindow() throws {
        let data = Data(
            """
            { "config": { "currentPeriod": { "type": "USAGE_PERIOD_TYPE_MONTHLY", "end": "2026-10-01T00:00:00Z" }, "creditUsagePercent": 12.5 } }
            """.utf8)
        let limits = try GrokLimitsReader.limits(json: data, tier: "  ")
        #expect(limits.week?.period == "monthly")
        #expect(limits.grok?.tier == nil)
        #expect(limits.grok?.products.isEmpty == true)
        #expect(limits.grok?.extraLine == nil)
        #expect(GrokPeriod.mark("monthly") == "Mo")
        #expect(GrokPeriod.duration("monthly") == 30 * 24 * 3600)
    }

    @Test func aPayloadWithoutAPercentIsUnavailable() {
        #expect(throws: GrokLimitsReader.Failure.unavailable) {
            try GrokLimitsReader.limits(json: Data(#"{"config":{}}"#.utf8), tier: nil)
        }
    }

    @Test func refreshDecodesTheReplacementToken() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let refresh = try GrokLimitsReader.refreshed(
            json: Data(
                #"{"access_token":"next","refresh_token":"later","expires_in":120}"#.utf8),
            now: now)
        #expect(refresh.accessToken == "next")
        #expect(refresh.refreshToken == "later")
        #expect(refresh.expiresAt == now.addingTimeInterval(120))
    }

    @Test func anEmptyRefreshTokenIsUnauthorized() {
        #expect(throws: GrokLimitsReader.Failure.unauthorized) {
            try GrokLimitsReader.refreshed(json: Data(#"{"access_token":""}"#.utf8))
        }
    }

    @Test func billingURLStaysOnTheOfficialProxyUnlessOverriddenWithHTTPS() {
        #expect(
            GrokLimitsReader.billingURL(environment: [:]).absoluteString
                == "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
        #expect(
            GrokLimitsReader.billingURL(environment: ["GROK_CLI_CHAT_PROXY_BASE_URL": "http://evil"]
            )
            .absoluteString
                == "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
        #expect(
            GrokLimitsReader.billingURL(
                environment: [
                    "GROK_CLI_CHAT_PROXY_BASE_URL": "https://cli-chat-proxy.grok.com/v1/"
                ]
            ).absoluteString == "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
    }

    @Test func authFileAndSettingsExposeTheSignedInSession() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-limits-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let grok = home.appendingPathComponent(".grok")
        try FileManager.default.createDirectory(at: grok, withIntermediateDirectories: true)
        let expiry = "2026-09-26T16:43:27.850647Z"
        try Data(
            """
            {"https://auth.x.ai::client":{"key":"access","refresh_token":"refresh","expires_at":"\(expiry)","oidc_client_id":"client"}}
            """.utf8
        ).write(to: grok.appendingPathComponent("auth.json"))
        try Data(
            """
            {"payload":"{\\"settings\\":{\\"subscription_tier_display\\":\\"SuperGrok\\"}}"}
            """.utf8
        ).write(to: grok.appendingPathComponent("settings_cache.json"))
        let material = try #require(GrokCredentialStore.load(home: home))
        #expect(material.accessToken == "access")
        #expect(material.refreshToken == "refresh")
        #expect(material.clientID == "client")
        #expect(material.expiresAt == EdithDate.parseISO(expiry))
        #expect(GrokCredentialStore.tierDisplay(home: home) == "SuperGrok")
        #expect(GrokCredentialStore.expiresSoon(material.expiresAt, now: material.expiresAt!))
        #expect(
            !GrokCredentialStore.expiresSoon(
                material.expiresAt, now: material.expiresAt!.addingTimeInterval(-180)))
    }

    @Test func historyRestoresTheAllowanceOntoTheWeeklyWindow() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-tests-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("limits-history.jsonl")
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let allowance = GrokAllowance(
            period: "monthly", tier: "SuperGrok Heavy",
            products: [GrokProductShare(name: "Build", percent: 12)],
            onDemandUsed: 0, onDemandCap: 0, prepaidBalance: 0)
        var history = LimitsHistory(url: url)
        let wrote = history.append(
            provider: .grok, session: nil,
            week: LimitWindow(
                percent: 12, resetsAt: now.addingTimeInterval(86_400), period: "monthly"),
            grok: allowance, now: now)
        #expect(wrote)
        let latest = try #require(LimitsHistory.latestProviders(url: url)[.grok])
        #expect(latest.week?.percent == 12)
        #expect(latest.week?.period == "monthly")
        #expect(latest.grok == allowance)
        history.append(
            provider: .grok, session: nil,
            week: LimitWindow(percent: 12, resetsAt: now.addingTimeInterval(86_400)),
            grok: allowance, now: now.addingTimeInterval(30))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 1)
    }
}
