import CoreMediaIO
import Foundation

let providerSource = CameraProviderSource(bundle: .main)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
