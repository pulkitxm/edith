import AppKit
import EdithKit
import SwiftUI

struct ExportCardPresentation<Deck: ExportCardDeck>: Identifiable {
    let id = UUID()
    let deck: Deck
    let title: String
}

extension View {
    func exportCardPresentation<Deck: ExportCardDeck>(
        item: Binding<ExportCardPresentation<Deck>?>
    ) -> some View {
        modifier(ExportCardPresentationModifier(item: item))
    }
}

private struct ExportCardPresentationModifier<Deck: ExportCardDeck>: ViewModifier {
    @Binding var item: ExportCardPresentation<Deck>?
    @State private var busy = false

    func body(content: Content) -> some View {
        content.edithSheet(item: $item, dismissible: !busy) { presentation in
            let scopedBusy = Binding(
                get: { item?.id == presentation.id && busy },
                set: { if item?.id == presentation.id { busy = $0 } })
            ExportCardSheet(deck: presentation.deck, title: presentation.title, busy: scopedBusy) {
                item = nil
            }
            .id(presentation.id)
        }
        .onChange(of: item?.id) { _, _ in busy = false }
    }
}

struct ExportCardButton: View {
    let isEnabled: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label("Share", systemImage: "square.and.arrow.up") }
            .buttonStyle(.edith(.secondary))
            .disabled(!isEnabled)
            .keyboardShortcut("e", modifiers: .command)
            .help("\(help) (⌘E)")
    }
}

struct ExportCardSheet<Deck: ExportCardDeck>: View {
    let deck: Deck
    let title: String
    @Binding var busy: Bool
    let onDismiss: () -> Void
    var pasteboard: NSPasteboard = .general
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
    @State private var index = 0
    @State private var direction = 1
    @State private var copied = false
    @State private var copyCount = 0
    @State private var previews: [Deck.Card: NSImage] = [:]
    @State private var previewErrors: [Deck.Card: String] = [:]
    @State private var previewAttempt = 0
    @State private var status: ExportCardStatus?
    @State private var actionTask: Task<Void, Never>?

    private var dark: Bool { scheme == .dark }
    private var theme: AppTheme { AppTheme(storedName: themeName) }
    private var card: Deck.Card { deck.cards[index] }

    var body: some View {
        VStack(spacing: UIScale.pt(16)) {
            HStack {
                Text(title).font(DashSkin.heading(18))
                Spacer()
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.edith(.iconOnly))
                    .disabled(busy)
                    .accessibilityLabel("Close export")
                    .help("Close (Escape)")
            }
            GeometryReader { geometry in
                preview
                    .frame(width: min(geometry.size.width, geometry.size.height * 1.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: UIScale.pt(12)) {
                arrow("chevron.left", shortcut: .leftArrow, movement: -1)
                Text(deck.title(for: card))
                    .font(DashSkin.heading(14))
                    .lineLimit(1)
                Text("\(index + 1) / \(deck.cards.count)")
                    .font(DashSkin.mono(11))
                    .foregroundStyle(DashSkin.inkSoft(dark, theme: theme))
                arrow("chevron.right", shortcut: .rightArrow, movement: 1)
            }
            pagination
            HStack(spacing: UIScale.pt(12)) {
                Button {
                    deliver(save: false)
                } label: {
                    HStack(spacing: UIScale.pt(6)) {
                        Text(copied ? "Copied!" : "Copy image")
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                            .symbolEffect(
                                .bounce, options: .nonRepeating, value: reduceMotion ? 0 : copyCount
                            )
                    }
                }
                .buttonStyle(.edith(.primary))
                .keyboardShortcut("c", modifiers: .command)
                .help("Copy image (⌘C)")
                Button {
                    deliver(save: true)
                } label: {
                    Label("Save PNG", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.edith(.secondary))
                .keyboardShortcut("s", modifiers: .command)
                .help("Save PNG (⌘S)")
                if busy { LoadingIndicator() }
            }
            .disabled(busy || previews[card] == nil)
            Group {
                if let status {
                    Label(
                        status.message,
                        systemImage: status.failed ? "exclamationmark.triangle" : "checkmark.circle"
                    )
                    .foregroundStyle(
                        status.failed ? DashSkin.danger : DashSkin.inkSoft(dark, theme: theme)
                    )
                    .id(status.id)
                    .transition(
                        Motion.transition(
                            .move(edge: .bottom).combined(with: .opacity),
                            reduceMotion: reduceMotion, preferCrossFade: false))
                } else {
                    Text("⌘C to copy · ⌘S to save · Escape to close")
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
            .font(.system(size: UIScale.pt(11)))
            .lineLimit(2)
            .frame(height: UIScale.pt(28))
        }
        .padding(UIScale.pt(20))
        .frame(
            width: PresentationMetrics.width(720),
            height: PresentationMetrics.height(610)
        )
        .foregroundStyle(DashSkin.ink(dark, theme: theme))
        .background(DashSkin.paper2(dark, theme: theme))
        .task(id: "\(index):\(previewAttempt)") { await loadPreview() }
        .task(id: status?.id) {
            guard status != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.animation(Motion.feedback, reduceMotion: reduceMotion)) {
                status = nil
                copied = false
            }
        }
        .onDisappear {
            actionTask?.cancel(); busy = false
        }
    }

    private var preview: some View {
        LoadingContainer(
            state: previews[card] != nil
                ? .content : previewErrors[card] != nil ? .error : .loading,
            message: previewErrors[card] ?? "Preparing your card.",
            retry: {
                previewErrors[card] = nil; previewAttempt += 1
            }
        ) {
            if let image = previews[card] {
                Image(nsImage: image).resizable().scaledToFit()
                    .id(card)
                    .transition(
                        Motion.transition(
                            .asymmetric(
                                insertion: .move(edge: direction > 0 ? .trailing : .leading),
                                removal: .move(edge: direction > 0 ? .leading : .trailing)),
                            reduceMotion: reduceMotion, preferCrossFade: false))
            }
        } placeholder: {
            SkeletonGroup {
                VStack(spacing: UIScale.pt(16)) {
                    SkeletonBlock(width: 170, height: 18)
                    SkeletonBlock(height: 76, corner: 12)
                    SkeletonBlock(height: 120, corner: 12)
                    SkeletonBlock(width: 140, height: 10)
                }
                .padding(UIScale.pt(24))
            }
        }
        .aspectRatio(3.0 / 2.0, contentMode: .fit)
        .frame(maxWidth: UIScale.pt(600))
        .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(12)))
        .gesture(
            DragGesture(minimumDistance: 18).onEnded { gesture in
                guard abs(gesture.translation.width) > 50, !busy else { return }
                move(gesture.translation.width < 0 ? 1 : -1)
            })
    }

    private func arrow(_ symbol: String, shortcut: KeyEquivalent, movement: Int) -> some View {
        Button {
            move(movement)
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(.edith(.iconOnly))
        .keyboardShortcut(shortcut, modifiers: [])
        .disabled(busy || deck.cards.count < 2)
        .accessibilityLabel(movement < 0 ? "Previous card" : "Next card")
    }

    private func move(_ movement: Int) {
        select((index + movement + deck.cards.count) % deck.cards.count, direction: movement)
    }

    private var pagination: some View {
        HStack(spacing: UIScale.pt(6)) {
            ForEach(deck.cards.indices, id: \.self) { destination in
                Button {
                    select(destination, direction: destination > index ? 1 : -1)
                } label: {
                    Circle()
                        .fill(
                            destination == index
                                ? DashSkin.ink(dark, theme: theme)
                                : DashSkin.inkFaint(dark).opacity(0.3)
                        )
                        .frame(
                            width: UIScale.pt(destination == index ? 7 : 6),
                            height: UIScale.pt(destination == index ? 7 : 6)
                        )
                        .frame(width: UIScale.pt(16), height: UIScale.pt(16))
                }
                .buttonStyle(.edith(.borderless))
                .disabled(busy)
                .accessibilityLabel(deck.title(for: deck.cards[destination]))
                .accessibilityAddTraits(destination == index ? .isSelected : [])
            }
        }
    }

    private func select(_ destination: Int, direction: Int) {
        guard !busy, destination != index else { return }
        self.direction = direction
        withAnimation(Motion.animation(Motion.snap, reduceMotion: reduceMotion)) {
            index = destination
            status = nil
            copied = false
        }
    }

    private func loadPreview() async {
        let candidates = [
            index, (index + 1) % deck.cards.count,
            (index + deck.cards.count - 1) % deck.cards.count,
        ]
        for destination in candidates {
            let selected = deck.cards[destination]
            guard previews[selected] == nil, previewErrors[selected] == nil else { continue }
            await Task.yield()
            guard !Task.isCancelled else { return }
            do {
                previews[selected] = try ExportCardRenderer.image(
                    deck.content(for: selected), scale: 1)
            } catch {
                previewErrors[selected] = error.localizedDescription
            }
        }
    }

    private func deliver(save: Bool) {
        guard !busy else { return }
        actionTask?.cancel()
        let selected = card
        let window = NSApp.keyWindow
        busy = true
        actionTask = Task { @MainActor in
            defer { busy = false }
            do {
                let url: URL?
                if save {
                    url = await ExportDelivery.chooseSaveURL(
                        suggestedName: deck.filename(for: selected), in: window)
                    guard url != nil else { return }
                } else {
                    url = nil
                }
                await Task.yield()
                try Task.checkCancellation()
                let data = try ExportCardRenderer.pngData(deck.content(for: selected))
                if let url {
                    try ExportDelivery.write(data, to: url)
                    showStatus(ExportCardStatus(message: "Saved to \(url.lastPathComponent)"))
                } else {
                    try ExportDelivery.copyPNG(data, to: pasteboard)
                    withAnimation(Motion.animation(Motion.feedback, reduceMotion: reduceMotion)) {
                        copied = true
                        copyCount += 1
                    }
                    showStatus(ExportCardStatus(message: "Image copied"))
                }
            } catch is CancellationError {
            } catch {
                showStatus(ExportCardStatus(message: error.localizedDescription, failed: true))
            }
        }
    }

    private func showStatus(_ status: ExportCardStatus) {
        withAnimation(Motion.animation(Motion.feedback, reduceMotion: reduceMotion)) {
            if status.failed { copied = false }
            self.status = status
        }
    }
}

private struct ExportCardStatus {
    let id = UUID()
    let message: String
    var failed = false
}
