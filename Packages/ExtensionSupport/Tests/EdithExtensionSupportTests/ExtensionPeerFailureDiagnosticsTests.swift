import Foundation
import Network
import Testing

@testable import EdithExtensionSupport

private final class PeerDiagnosticProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [Data] = []
    func append(_ row: Data) { lock.withLock { rows.append(row) } }
    func snapshot() -> [Data] { lock.withLock { rows } }
}

@Suite struct ExtensionPeerFailureDiagnosticsTests {
    @Test func closedRowsContainOnlyFiniteStageAndBoundedNumericError() throws {
        let probe = PeerDiagnosticProbe()
        let recorder = ExtensionPeerFailureDiagnostics.Recorder(sink: { probe.append($0) })
        recorder.report(.connectionFailed, errorNumber: 61)
        recorder.report(.serverPeerIdentity, errorNumber: -1)
        recorder.report(.registrationDecode, errorNumber: 4096)
        let rows = try probe.snapshot().map {
            try #require(JSONSerialization.jsonObject(with: $0) as? [String: [String: Any]])
        }
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { Set($0.keys) == ["peerFailure"] })
        let first = try #require(rows.first?["peerFailure"])
        #expect(Set(first.keys) == ["stage", "errno"])
        #expect(first["stage"] as? String == "connection_failed")
        #expect(first["errno"] as? Int == 61)
        for row in rows.dropFirst() {
            let fields = try #require(row["peerFailure"])
            #expect(Set(fields.keys) == ["stage"])
        }
        let labels = Set(ExtensionPeerFailureDiagnostics.Stage.allCases.map(\.rawValue))
        #expect(rows.allSatisfy { labels.contains($0["peerFailure"]?["stage"] as? String ?? "") })
        #expect(probe.snapshot().allSatisfy { $0.last == 10 && $0.count <= 128 })
    }

    @Test func repeatedFailureDoesNotConsumeTheRemainingDistinctStageBudget() throws {
        let probe = PeerDiagnosticProbe()
        let recorder = ExtensionPeerFailureDiagnostics.Recorder(
            capacity: 2, sink: { probe.append($0) })
        for _ in 0..<100 { recorder.report(.registrationOpen, errorNumber: 2) }
        recorder.report(.serverPeerPID, errorNumber: 22)
        recorder.report(.serverPeerIdentity)
        let rows = probe.snapshot()
        #expect(rows.count == 2)
        #expect(String(decoding: rows[1], as: UTF8.self).contains("server_peer_pid"))
        #expect(!String(decoding: rows[1], as: UTF8.self).contains("server_peer_identity"))
    }

    @Test func oversizedAndNegativeCapacitiesCannotExpandOrEnableOutput() {
        let bounded = PeerDiagnosticProbe()
        let recorder = ExtensionPeerFailureDiagnostics.Recorder(
            capacity: Int.max, sink: { bounded.append($0) })
        for stage in ExtensionPeerFailureDiagnostics.Stage.allCases { recorder.report(stage) }
        #expect(bounded.snapshot().count == 16)
        let disabled = PeerDiagnosticProbe()
        let muted = ExtensionPeerFailureDiagnostics.Recorder(
            capacity: -1, sink: { disabled.append($0) })
        for stage in ExtensionPeerFailureDiagnostics.Stage.allCases { muted.report(stage) }
        #expect(disabled.snapshot().isEmpty)
    }

    @Test func absentFailuresProduceNoRowAndPreserveTheFirstFailure() {
        let probe = PeerDiagnosticProbe()
        let recorder = ExtensionPeerFailureDiagnostics.Recorder(
            capacity: 1, sink: { probe.append($0) })
        for _ in 0..<100 { recorder.report(nil, errorNumber: 61) }
        #expect(probe.snapshot().isEmpty)
        recorder.report(.registrationDecode)
        #expect(probe.snapshot().count == 1)
    }

    @Test func concurrentFailuresRetainTheSameProcessBound() async {
        let probe = PeerDiagnosticProbe()
        let recorder = ExtensionPeerFailureDiagnostics.Recorder(sink: { probe.append($0) })
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                for stage in ExtensionPeerFailureDiagnostics.Stage.allCases {
                    group.addTask { recorder.report(stage) }
                }
            }
        }
        #expect(probe.snapshot().count == 16)
    }
}
