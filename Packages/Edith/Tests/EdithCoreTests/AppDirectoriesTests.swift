import Foundation
import Testing

@testable import EdithCore

@Suite struct AppDirectoriesTests {
    @Test func macOSDirectoriesPreserveExistingDataLocation() {
        let home = URL(fileURLWithPath: "/Users/example")
        let directories = AppDirectories(homeDirectory: home)

        #expect(
            directories.configuration.path
                == "/Users/example/Library/Application Support/Edith")
        #expect(directories.data == directories.configuration)
        #expect(directories.cache.path == "/Users/example/Library/Caches/Edith")
    }
}
