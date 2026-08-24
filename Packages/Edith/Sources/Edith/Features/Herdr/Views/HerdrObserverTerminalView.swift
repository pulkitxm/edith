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

private struct HerdrObserverEnvelope: Decodable {
    let type: String
    let bytes: String?
}

final class HerdrObserverTerminalView: LocalProcessTerminalView {
    private var decoder = HerdrObserverStreamDecoder()

    override func dataReceived(slice: ArraySlice<UInt8>) {
        for output in decoder.append(slice) {
            switch output {
            case .frame(let bytes), .text(let bytes):
                feed(byteArray: Array(bytes)[...])
            }
        }
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {}
}
