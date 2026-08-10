import Foundation
import Testing

@testable import EdithCore

@Suite struct AppDirectoriesTests {
    @Test func macOSDirectoriesPreserveExistingDataLocation() {
        let home = URL(fileURLWithPath: "/Users/example")
        let directories = AppDirectories(platform: .macOS, homeDirectory: home)

        #expect(
            directories.configuration.path
                == "/Users/example/Library/Application Support/Edith")
        #expect(directories.data == directories.configuration)
        #expect(directories.cache.path == "/Users/example/Library/Caches/Edith")
    }

    @Test func linuxDirectoriesFollowXDGEnvironment() {
        let directories = AppDirectories(
            platform: .linux,
            homeDirectory: URL(fileURLWithPath: "/home/example"),
            environment: [
                "XDG_CONFIG_HOME": "/mnt/config",
                "XDG_DATA_HOME": "/mnt/data",
                "XDG_CACHE_HOME": "/mnt/cache",
                "XDG_RUNTIME_DIR": "/run/user/1000",
            ])

        #expect(directories.configuration.path == "/mnt/config/edith")
        #expect(directories.data.path == "/mnt/data/edith")
        #expect(directories.cache.path == "/mnt/cache/edith")
        #expect(directories.runtime.path == "/run/user/1000/edith")
    }

    @Test func linuxDirectoriesRejectRelativeXDGValues() {
        let directories = AppDirectories(
            platform: .linux,
            homeDirectory: URL(fileURLWithPath: "/home/example"),
            environment: [
                "XDG_CONFIG_HOME": "config",
                "XDG_DATA_HOME": "data",
                "XDG_CACHE_HOME": "cache",
                "XDG_RUNTIME_DIR": "runtime",
            ])

        #expect(directories.configuration.path == "/home/example/.config/edith")
        #expect(directories.data.path == "/home/example/.local/share/edith")
        #expect(directories.cache.path == "/home/example/.cache/edith")
        #expect(directories.runtime.path == "/home/example/.cache/edith/runtime/edith")
    }
}
