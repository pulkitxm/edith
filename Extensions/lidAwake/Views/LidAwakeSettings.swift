import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct LidAwakeSettings: View {
    let model: LidAwakeSettingsModel
    var body: some View {
        Form {
            LidAwakeRows(operations: model.operations, chooseSession: model.setSession)
        }
        .edithForm()
    }
}
