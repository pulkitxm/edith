import Foundation
import SwiftTerm

enum HerdrObserverOutput: Equatable {
    case frame(Data)
    case text(Data)
}

struct HerdrObserverStreamDecoder {
    private var pending = Data()

    mutating func append(_ bytes: ArraySlice<UInt8>) -> [HerdrObserverOutput] {
        pending.append(contentsOf: bytes)
        var output: [HerdrObserverOutput] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var line = pending[..<newline]
            pending.removeSubrange(...newline)
            if line.last == 0x0D { line = line.dropLast() }
            guard !line.isEmpty else { continue }
            output.append(decode(Data(line)))
        }
        return output
    }

    private func decode(_ line: Data) -> HerdrObserverOutput {
        guard let envelope = try? JSONDecoder().decode(HerdrObserverEnvelope.self, from: line),
            envelope.type == "terminal.frame",
            let encoded = envelope.bytes,
            let bytes = Data(base64Encoded: encoded)
        else {
            return .text(line + Data([0x0D, 0x0A]))
        }
        return .frame(bytes)
    }
}

struct HerdrObserverFrameGate {
    private var followsLiveOutput = true
    private var pendingFrame: Data?

    mutating func receive(_ frame: Data) -> Data? {
        guard followsLiveOutput else {
            pendingFrame = frame
            return nil
        }
        return frame
    }

    mutating func scroll(position: Double, canScroll: Bool) -> Data? {
        followsLiveOutput = !canScroll || position >= 1
        guard followsLiveOutput, let pendingFrame else { return nil }
        self.pendingFrame = nil
        return pendingFrame
    }
}

private struct HerdrObserverEnvelope: Decodable {
    let type: String
    let bytes: String?
}

final class HerdrObserverTerminalView: LocalProcessTerminalView {
    private var decoder = HerdrObserverStreamDecoder()
    private var frameGate = HerdrObserverFrameGate()

    override func dataReceived(slice: ArraySlice<UInt8>) {
        for output in decoder.append(slice) {
            switch output {
            case .frame(let bytes):
                guard let frame = frameGate.receive(bytes) else { continue }
                feed(byteArray: Array(frame)[...])
            case .text(let bytes):
                feed(byteArray: Array(bytes)[...])
            }
        }
    }

    override func scrolled(source: TerminalView, position: Double) {
        guard let frame = frameGate.scroll(position: position, canScroll: canScroll) else {
            return
        }
        feed(byteArray: Array(frame)[...])
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {}
}
