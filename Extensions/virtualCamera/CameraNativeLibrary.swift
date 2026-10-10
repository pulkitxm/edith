import Darwin
import Foundation

final class ExtensionNativeLibrary {
    private let handle: UnsafeMutableRawPointer

    private init(url: URL) throws {
        guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            throw MeetingAudioLibrary.error(
                "The installed voice inference component could not be loaded.")
        }
        self.handle = handle
    }

    static func load() throws -> ExtensionNativeLibrary {
        let bundle = Bundle(for: CameraNativeResourceMarker.self)
        let url = bundle.bundleURL.appendingPathComponent(
            "Contents/Frameworks/libMeetingVoice.dylib")
        return try ExtensionNativeLibrary(url: url)
    }

    func symbol<T>(_ name: String, as type: T.Type) throws -> T {
        guard let symbol = dlsym(handle, name),
            MemoryLayout<T>.size == MemoryLayout<UnsafeMutableRawPointer>.size
        else {
            throw MeetingAudioLibrary.error("The voice inference component is incompatible.")
        }
        return unsafeBitCast(symbol, to: type)
    }

    deinit { dlclose(handle) }
}

private final class CameraNativeResourceMarker: NSObject {}
