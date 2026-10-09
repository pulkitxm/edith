import EdithExtensionSupport
import Foundation

protocol PresenterDeciding: Sendable {
    func probability(windows: String) async throws -> Double?
}

struct PresenterJevClient: PresenterDeciding {
    let endpoint: ExtensionPeerEndpoint

    static func configured() -> Self? {
        guard ExtensionSharedState.current?.values(for: "jev")["configured"] == "1",
            let endpoint = ExtensionPeerEndpoint.current(owner: "jev")
        else { return nil }
        return Self(endpoint: endpoint)
    }

    static func request(windows: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "purpose": "presenter.detect",
            "request": [
                "model": "jev-latest",
                "state": ["windows": windows],
                "questions": [
                    "presenting": [
                        "type": "noul",
                        "instructions":
                            "The user is sharing their screen or presenting in a call, judging by `windows`.",
                    ]
                ],
            ],
        ])
    }

    func probability(windows: String) async throws -> Double? {
        let reply = try await endpoint.invoke(
            "jev.decide", payload: Self.request(windows: windows), timeout: 12)
        let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any]
        let decision = object?["decision"] as? [String: Any]
        let response = decision?["response"] as? [String: Any]
        let answers = response?["answers"] as? [String: Any]
        let answer = answers?["presenting"] as? [String: Any]
        guard let probability = answer?["noul"] as? Double,
            probability.isFinite, (0...1).contains(probability)
        else { return nil }
        return probability
    }
}
