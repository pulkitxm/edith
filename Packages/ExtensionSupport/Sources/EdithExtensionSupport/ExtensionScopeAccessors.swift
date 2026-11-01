import EdithExtensionCore
import Foundation

extension SurfaceHostContext {
    public static var current: Self? { current(in: ExtensionEnvironment.scope) }
}

extension ExtensionSharedState {
    public static var current: Self? { current(in: ExtensionEnvironment.scope) }
}

extension ExtensionCommandOwnership {
    public static var isWorker: Bool { isWorker(in: ExtensionEnvironment.scope) }
}
