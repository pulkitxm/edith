import EdithExtensionSupport
import SwiftUI

extension Binding {
    public func notifyingSettingsChange() -> Binding<Value> {
        Binding(
            get: { wrappedValue },
            set: { value in
                wrappedValue = value
                IPC.post(IPC.Name.settingsChanged)
            })
    }
}
