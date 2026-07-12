import AppKit
import EdithKit
import SwiftUI

struct ScratchpadView: View {
    let onDismiss: () -> Void
    @State private var input = ""
    @FocusState private var focused: Bool

    private var result: String? {
        QuickCalc.evaluate(input)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("2 + 2, or 10 km to mi", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .focused($focused)
                .onSubmit(copyAndDismiss)
            if let result {
                Text(result)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .onAppear { focused = true }
        .onExitCommand(perform: onDismiss)
    }

    private func copyAndDismiss() {
        if let result {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result, forType: .string)
        }
        onDismiss()
    }
}
