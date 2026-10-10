import Darwin
import EdithExtensionSupport
import Foundation

private final class MusicResourceIdentity: NSObject {}

public final class MusicNativePlayer: @unchecked Sendable {
    private typealias Callback =
        @convention(c) (UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?) -> Void
    private typealias Start =
        @convention(c) (
            UnsafePointer<CChar>?, Int, UnsafePointer<CChar>?, Int, Int32, Callback?,
            UnsafeMutableRawPointer?
        ) -> UnsafeMutableRawPointer?
    private typealias Send =
        @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Bool
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias Forget = @convention(c) (UnsafePointer<CChar>?, Int) -> Bool

    private final class Receiver {
        let receive: @Sendable (Data) -> Void
        let onExit: @Sendable () -> Void
        init(receive: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable () -> Void) {
            self.receive = receive
            self.onExit = onExit
        }
    }

    public static var applicationIdentity: String {
        ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            ?? Bundle.main.bundleIdentifier ?? "com.pulkit.edith.development"
    }
    public static var keychainService: String { applicationIdentity + ".extension.music" }
    public static var libraryURL: URL? {
        Bundle(for: MusicResourceIdentity.self).privateFrameworksURL?.appendingPathComponent(
            "libedith_music_player.dylib")
    }

    private let lock = NSLock()
    private var library: UnsafeMutableRawPointer?
    private var handle: UnsafeMutableRawPointer?
    private var receiver: UnsafeMutableRawPointer?
    private let sendFunction: Send
    private let stopFunction: Stop

    public init(
        libraryURL: URL, service: String, name: String, resume: Bool,
        receive: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable () -> Void
    ) throws {
        guard Self.validText(service, maximum: 256), Self.validText(name, maximum: 128) else {
            throw CocoaError(.executableLoad)
        }
        guard let library = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            throw CocoaError(.executableNotLoadable)
        }
        guard let start = dlsym(library, "edith_music_player_start"),
            let send = dlsym(library, "edith_music_player_send"),
            let stop = dlsym(library, "edith_music_player_stop")
        else {
            dlclose(library)
            throw CocoaError(.executableNotLoadable)
        }
        self.library = library
        sendFunction = unsafeBitCast(send, to: Send.self)
        stopFunction = unsafeBitCast(stop, to: Stop.self)
        let box = Unmanaged.passRetained(Receiver(receive: receive, onExit: onExit)).toOpaque()
        receiver = box
        let callback: Callback = { bytes, count, context in
            guard let bytes, let context, count > 0, count <= 65_536 else { return }
            let box = Unmanaged<Receiver>.fromOpaque(context).takeUnretainedValue()
            let data = Data(bytes: bytes, count: count)
            if let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                event["event"] as? String == "terminated"
            {
                box.onExit()
            } else {
                box.receive(data + Data([10]))
            }
        }
        let startFunction = unsafeBitCast(start, to: Start.self)
        let serviceLength = service.utf8.count
        let nameLength = name.utf8.count
        handle = service.withCString { service in
            name.withCString { name in
                startFunction(
                    service, serviceLength, name, nameLength, resume ? 1 : 0, callback, box)
            }
        }
        guard handle != nil else {
            Unmanaged<Receiver>.fromOpaque(box).release()
            receiver = nil
            dlclose(library)
            self.library = nil
            throw CocoaError(.executableLoad)
        }
    }

    deinit { stop() }

    public func send(_ data: Data, onError: @escaping @Sendable () -> Void) {
        let accepted = lock.withLock {
            guard let handle, data.count <= 4096 else { return false }
            return data.withUnsafeBytes { bytes in
                sendFunction(handle, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            }
        }
        if !accepted { onError() }
    }

    public func stop() {
        lock.withLock {
            if let handle { stopFunction(handle); self.handle = nil }
            if let receiver {
                Unmanaged<Receiver>.fromOpaque(receiver).release(); self.receiver = nil
            }
            if let library { dlclose(library); self.library = nil }
        }
    }

    private static func validText(_ value: String, maximum: Int) -> Bool {
        (1...maximum).contains(value.utf8.count) && !value.utf8.contains(0)
    }

    public static func forget(libraryURL: URL, service: String) -> Bool {
        guard validText(service, maximum: 256) else { return false }
        guard let library = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else { return false }
        defer { dlclose(library) }
        guard let function = dlsym(library, "edith_music_player_forget") else { return false }
        let forget = unsafeBitCast(function, to: Forget.self)
        return service.withCString { forget($0, service.utf8.count) }
    }
}
