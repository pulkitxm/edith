import Foundation

public enum AppPlatform: String, Codable, Hashable, Sendable {
    case macOS
    case linux

    public static var current: AppPlatform {
        #if os(macOS)
        .macOS
        #elseif os(Linux)
        .linux
        #else
        fatalError("Unsupported platform")
        #endif
    }
}
