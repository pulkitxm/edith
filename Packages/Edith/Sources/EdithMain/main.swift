import Darwin
import Edith
import EdithCLI
import EdithDatabase
import Foundation

switch ExecutableLaunch.destination(environment: ProcessInfo.processInfo.environment) {
case .application:
    EdithApp.main()
case .commandLine:
    await EdithCLIMain.run()
case .databaseBroker:
    Darwin.exit(await DatabaseBrokerProcess.run())
}
