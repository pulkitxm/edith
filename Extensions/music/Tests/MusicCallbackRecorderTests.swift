import Foundation
import Testing

@Suite struct MusicCallbackRecorderTests {
    @Test func concurrentCallbacksAndSnapshotsRetainEveryEvent() async {
        let recorder = MusicCallbackRecorder<Int>()
        await withTaskGroup(of: Void.self) { group in
            for batch in 0..<32 {
                group.addTask {
                    for offset in 0..<128 {
                        recorder.append(batch * 128 + offset)
                        let snapshot = recorder.values
                        #expect(snapshot.count == Set(snapshot).count)
                    }
                }
            }
        }
        #expect(recorder.values.sorted() == Array(0..<4096))
    }

    @Test func snapshotDoesNotChangeWhenALaterCallbackArrives() {
        let recorder = MusicCallbackRecorder<String>()
        recorder.append("A")
        let prior = recorder.values
        recorder.append("B")
        #expect(prior == ["A"])
        #expect(recorder.values == ["A", "B"])
    }
}
