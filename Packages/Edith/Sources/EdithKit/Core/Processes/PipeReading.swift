import Foundation

enum PipeReading {
    @discardableResult
    static func consume(_ handle: FileHandle, receive: (Data) -> Void) -> Bool {
        let data = handle.availableData
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            return false
        }
        receive(data)
        return true
    }
}
