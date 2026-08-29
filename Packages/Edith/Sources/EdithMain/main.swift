import Edith
import EdithCLI
import Foundation

let executableName = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent.lowercased()
if ["ed", "edith"].contains(executableName) {
    await EdithCLIMain.run()
} else {
    EdithApp.main()
}
