import Foundation
@testable import Edith
@testable import EdithKit
import Testing

@Suite struct HerdrDropTransferTests {
    @Test func remoteDropPathsAreTemporaryUniqueAndShellSafe() {
        let url = URL(fileURLWithPath: "/Users/me/Desktop/my image (final).png")
        let path = HerdrDropTransfer.remotePath(
            for: url, directory: "/tmp", identifier: "1234")

        #expect(path == "/tmp/edith-drop-1234-my_image__final_.png")
        #expect(ShellQuote.quote(path) == path)
    }

    @Test func remoteDropPathsUseTheWindowsTemporaryDirectory() {
        let url = URL(fileURLWithPath: "/Users/me/Desktop/my image.png")
        let path = HerdrDropTransfer.remotePath(
            for: url, directory: "C:\\Users\\me\\AppData\\Local\\Temp\\",
            identifier: "5678")

        #expect(path == "C:\\Users\\me\\AppData\\Local\\Temp\\edith-drop-5678-my_image.png")
    }
}
