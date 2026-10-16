import Foundation

enum UsageNativePricing {
    struct Estimate {
        let cost: Double
        let missing: Bool
        let fallback: Bool
    }

    private static let rates: [String: [String: Double]] =
        (try? JSONDecoder().decode(
            [String: [String: Double]].self,
            from: Data(UsageNativePricingSnapshot.json.utf8))) ?? [:]

    static func estimate(_ event: UsageNativeEvent) -> Estimate {
        if let recorded = event.recordedCost {
            return .init(cost: recorded, missing: false, fallback: false)
        }
        var model = event.model.lowercased()
        var fallback = event.estimated
        if model == "gpt-reserve" { model = "gpt-5.6-luna"; fallback = true }
        if model == "codex-auto-review" {
            model =
                event.timestamp >= Date(timeIntervalSince1970: 1_785_369_600)
                ? "gpt-5.6-luna" : "gpt-5.4"
            fallback = true
        }
        let candidates = [
            model, "anthropic/" + model, "openai/" + model,
            model.split(separator: "/").last.map(String.init) ?? model,
        ]
        guard let rate = candidates.compactMap({ rates[$0] }).first else {
            return .init(cost: 0, missing: true, fallback: true)
        }
        let input = event.tokens.input + event.tokens.creation + event.tokens.read
        let tier: String
        switch event.serviceTier {
        case "priority", "fast": tier = "_priority"
        case "flex": tier = "_flex"
        case "ultrafast": tier = "_ultrafast"
        default: tier = ""
        }
        let thresholds = rate.keys.compactMap { key -> Int? in
            guard key.hasPrefix("input_cost_per_token_above_"), key.contains("k_tokens") else {
                return nil
            }
            let part = key.replacingOccurrences(of: "input_cost_per_token_above_", with: "")
                .components(separatedBy: "k_tokens")[0]
            return Int(part).map { $0 * 1000 }
        }
        let threshold = thresholds.filter { input > Double($0) }.max()
        let suffix = threshold.map { "_above_" + String($0 / 1000) + "k_tokens" } ?? ""
        func value(_ name: String, fallback defaultRate: Double) -> Double {
            rate[name + suffix + tier] ?? rate[name + suffix] ?? rate[name + tier] ?? rate[name]
                ?? defaultRate
        }
        let freshRate = value("input_cost_per_token", fallback: 0)
        let outputRate = value("output_cost_per_token", fallback: 0)
        let readRate = value("cache_read_input_token_cost", fallback: freshRate)
        let writeRate = value("cache_creation_input_token_cost", fallback: freshRate)
        let hourRate = rate["cache_creation_input_token_cost_above_1hr"] ?? writeRate
        let cost =
            event.tokens.input * freshRate + event.tokens.output * outputRate
            + event.tokens.read * readRate + max(
                0, event.tokens.creation - event.tokens.creationHour) * writeRate
            + event.tokens.creationHour * hourRate
        if !tier.isEmpty, rate["input_cost_per_token" + tier] == nil { fallback = true }
        return .init(cost: cost, missing: false, fallback: fallback)
    }
}
