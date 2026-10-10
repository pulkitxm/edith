import EdithExtensionUI
import SwiftUI

struct TerminalPage: View {
    let model: TerminalTabsModel
    let onWindowClose: () -> Void
    @Environment(\.windowVisible) private var visible

    var body: some View {
        TerminalTabsView(
            model: model, presented: visible, onWindowClose: onWindowClose,
            onWindowShow: { model.ensureFirstTab() }
        )
        .frame(minWidth: UIScale.pt(520), minHeight: UIScale.pt(320))
    }
}
