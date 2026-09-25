import Darwin
import Edith
import EdithCLI
import EdithDatabase
import Foundation

DatabaseExtensionReadiness.install()

switch ExecutableLaunch.destination(environment: ProcessInfo.processInfo.environment) {
case .application:
    EdithApp.main()
case .commandLine:
    await EdithCLIMain.run()
case .databaseBroker:
    Darwin.exit(await DatabaseBrokerProcess.run())
}
