import Foundation
@testable import Edith
@testable import EdithKit
import Testing

@Suite struct HerdrDropTransferTests {
    @Test func remoteDropPathsAreTemporaryUniqueAndShellSafe() {
        let url = URL(fileURLWithPath: "/Users/me/Desktop/my image (final).png")
        let path = HerdrDropTransfer.remotePath(for: url, identifier: "1234")

        #expect(path == "/tmp/edith-drop-1234-my_image__final_.png")
        #expect(ShellQuote.quote(path) == path)
    }
}
