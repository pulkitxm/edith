import EdithExtensionCommands
import Foundation

struct CapturedCLIOutput: Sendable {
    let outputSink: (@Sendable (String, Bool) -> Void)?
    let rawOutputSink: (@Sendable (Data, Bool) -> Void)?

    static var current: Self {
        Self(
            outputSink: ExtensionCLIContext.outputSink,
            rawOutputSink: ExtensionCLIContext.rawOutputSink)
    }

    func text(_ text: String, error: Bool = false) {
        if let outputSink {
            outputSink(text, error)
        } else if let rawOutputSink {
            rawOutputSink(Data(text.utf8), error)
        } else {
            (error ? FileHandle.standardError : FileHandle.standardOutput).write(Data(text.utf8))
        }
    }

    func line(_ text: String) { self.text(text + "\n") }

    func data(_ data: Data, error: Bool) {
        if let rawOutputSink {
            rawOutputSink(data, error)
        } else {
            (error ? FileHandle.standardError : FileHandle.standardOutput).write(data)
        }
    }
}
