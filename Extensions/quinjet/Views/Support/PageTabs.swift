import EdithExtensionUI
import EdithExtensionSupport
import SwiftUI

struct PageTabPicker<Option: Hashable>: View {
    let title: String
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String
    @Environment(\.compactLayout) private var compact

    var body: some View {
        if compact {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.large)
            .font(.edithText(.body))
            .accessibilityLabel(title)
        } else {
            EdithSegmentedPicker(title, selection: $selection, options: options, label: label)
                .labelsHidden()
        }
    }
}

struct PageTabStrip<ID: Hashable, Content: View>: View {
    let selection: ID
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) { content() }
                .scrollIndicators(.automatic)
                .task(id: selection) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    withAnimation(Motion.animation(Motion.snap, reduceMotion: reduceMotion)) {
                        proxy.scrollTo(selection, anchor: .center)
                    }
                }
        }
    }
}
