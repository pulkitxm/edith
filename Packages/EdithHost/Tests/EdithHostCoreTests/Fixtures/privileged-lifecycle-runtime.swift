import Foundation

@MainActor private final class LifetimeRuntime: NSObject {
    @objc(invoke:completion:)
    func invoke(
        _ request: NSDictionary,
        completion: @escaping @convention(block) (NSData?, NSString?) -> Void
    ) {
        completion(Data() as NSData, nil)
    }

    @objc(prepareDisableWithCompletion:)
    func prepareDisable(completion: @escaping @convention(block) (NSError?) -> Void) {
        do {
            guard let path = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"]
            else {
                throw CocoaError(.fileNoSuchFile)
            }
            let file = URL(fileURLWithPath: path).appendingPathComponent(
                "restoration-callbacks.jsonl")
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(
                contentsOf: JSONSerialization.data(withJSONObject: [
                    "pid": ProcessInfo.processInfo.processIdentifier
                ]))
            try handle.write(contentsOf: Data([10]))
            completion(nil)
        } catch { completion(error as NSError) }
    }
}

@_cdecl("edith_extension_create")
public func createLifetimeRuntime() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(LifetimeRuntime()).toOpaque())
        })
}
