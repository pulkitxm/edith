import Darwin
import Foundation

nonisolated(unsafe) private var bridgeSignal: Int32 = 0

enum HerdrBridgeCancellation {
    static var isCancelled: Bool { bridgeSignal != 0 }
    static func cancel() { bridgeSignal = 1 }
    static func install() {
        bridgeSignal = 0
        for value in [SIGTERM, SIGHUP, SIGINT] {
            signal(value) { bridgeSignal = $0 }
        }
    }
}
