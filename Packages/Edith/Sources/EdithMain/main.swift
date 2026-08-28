import Edith
import Foundation

if ProcessInfo.processInfo.environment["EDITH_APPLICATION_ROLE"] == "files" {
    EdithFilesApp.main()
} else {
    EdithApp.main()
}
