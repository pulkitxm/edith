import Edith
import EdithCLI
import Foundation

if ExecutableLaunch.isApplication(environment: ProcessInfo.processInfo.environment) {
    EdithApp.main()
} else {
    await EdithCLIMain.run()
}
