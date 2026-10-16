import EdithExtensionSupport
import SwiftUI

struct SurfaceSliderDraft {
    private(set) var value: Double
    private(set) var isEditing = false
    private var originalValue: Double

    init(value: Double) { self.value = value; originalValue = value }

    mutating func synchronize(_ next: Double) {
        guard !isEditing, next.isFinite, (0...1).contains(next) else { return }
        value = next; originalValue = next
    }

    mutating func set(_ next: Double) {
        guard next.isFinite else { return }
        value = min(1, max(0, next))
    }

    mutating func editingChanged(_ editing: Bool) -> Double? {
        let wasEditing = isEditing
        isEditing = editing
        guard !editing, wasEditing, value != originalValue else { return nil }
        originalValue = value
        return value
    }

    mutating func cancel() { isEditing = false; value = originalValue }
}

struct SurfaceSliderControl: View {
    let slider: SurfaceSlider
    let adjust: ((SurfaceSlider, Double) -> Void)?
    @State private var draft: SurfaceSliderDraft

    init(slider: SurfaceSlider, adjust: ((SurfaceSlider, Double) -> Void)?) {
        self.slider = slider; self.adjust = adjust
        _draft = State(initialValue: SurfaceSliderDraft(value: slider.value))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            HStack {
                Label(slider.title, systemImage: slider.icon)
                Spacer(minLength: 0)
                Text(draft.value, format: .percent.precision(.fractionLength(0))).monospacedDigit()
            }.font(.edithText(.caption))
            Slider(value: Binding(get: { draft.value }, set: { draft.set($0) }), in: 0...1) {
                editing in
                if let value = draft.editingChanged(editing) { adjust?(slider, value) }
            }
            .accessibilityLabel(slider.title)
            .disabled(adjust == nil)
        }
        .onChange(of: slider.value) { _, value in draft.synchronize(value) }
        .onDisappear { draft.cancel() }
    }
}
