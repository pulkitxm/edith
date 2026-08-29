import AppKit
import EdithKit
import SwiftUI
import UniformTypeIdentifiers

struct UsageShareSheet: View {
    let snapshot: UsageShareSnapshot
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var index = 0
    @State private var direction = 1
    @State private var previews: [UsageShareCard: NSImage] = [:]
    @State private var copied = false
    @State private var status: UsageShareActionStatus?
    @State private var statusID = UUID()

    private var cards: [UsageShareCard] { UsageShareCard.allCases }
    private var card: UsageShareCard { cards[index] }
    private var dark: Bool { scheme == .dark }
    private var modalBackground: Color {
        dark
            ? Color(red: 0.075, green: 0.07, blue: 0.065)
            : Color(red: 0.992, green: 0.985, blue: 0.91)
    }
    private var modalInk: Color {
        dark
            ? Color(red: 0.965, green: 0.94, blue: 0.88)
            : Color(red: 0.075, green: 0.07, blue: 0.065)
    }
    private var actionForeground: Color { dark ? Color.black.opacity(0.9) : Color.white }

    var body: some View {
        VStack(spacing: 22) {
            carousel
            pagination
            actionBar
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 42)
        .frame(width: 820, height: 610)
        .background(sheetBackground)
        .background(escapeShortcut)
        .overlay(alignment: .bottomTrailing) { statusToast }
        .task { await loadPreviews() }
        .onExitCommand { onDismiss() }
    }

    private var carousel: some View {
        HStack(spacing: 18) {
            ShareCarouselArrow(
                systemImage: "chevron.left", shortcut: .leftArrow, color: modalInk
            ) { move(-1) }
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(modalInk.opacity(0.06))
                if let image = previews[card] {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(3 / 2, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .id(card)
                        .transition(cardTransition)
                } else {
                    ProgressView("Preparing your cards…")
                        .controlSize(.small)
                        .foregroundStyle(modalInk.opacity(0.58))
                }
            }
            .frame(width: 600, height: 400)
            .clipped()
            .shadow(color: .black.opacity(0.17), radius: 24, y: 14)
            .gesture(
                DragGesture(minimumDistance: 18)
                    .onEnded { gesture in
                        guard abs(gesture.translation.width) > 50 else { return }
                        move(gesture.translation.width < 0 ? 1 : -1)
                    })
            ShareCarouselArrow(
                systemImage: "chevron.right", shortcut: .rightArrow, color: modalInk
            ) { move(1) }
        }
        .frame(maxWidth: .infinity)
    }

    private var pagination: some View {
        HStack(spacing: 8) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { item in
                Button {
                    select(item.offset)
                } label: {
                    Circle()
                        .fill(
                            item.offset == index
                                ? modalInk : modalInk.opacity(0.11)
                        )
                        .frame(
                            width: item.offset == index ? 7 : 6,
                            height: item.offset == index ? 7 : 6
                        )
                        .frame(width: 11, height: 11)
                }
                .buttonStyle(.plain)
                .help(item.element.title)
                .accessibilityLabel(item.element.title)
                .accessibilityAddTraits(item.offset == index ? .isSelected : [])
            }
        }
        .animation(Motion.animation(Motion.feedback, reduceMotion: reduceMotion), value: index)
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button(action: copyImage) {
                HStack(spacing: 8) {
                    Text("Copy image")
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(actionForeground)
                .padding(.horizontal, 16)
                .frame(height: 42)
                .background(modalInk, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(SharePressedButtonStyle())
            .keyboardShortcut("c", modifiers: .command)
            .help("Copy image (⌘C)")
            Button(action: downloadImage) {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(actionForeground)
                    .frame(width: 42, height: 42)
                    .background(modalInk, in: Circle())
            }
            .buttonStyle(SharePressedButtonStyle())
            .keyboardShortcut("s", modifiers: .command)
            .help("Save PNG (⌘S)")
            .accessibilityLabel("Download PNG")
        }
    }

    private var sheetBackground: some View {
        modalBackground
    }

    private var escapeShortcut: some View {
        Button("Close", action: onDismiss)
            .keyboardShortcut(.escape, modifiers: [])
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var statusToast: some View {
        if let status {
            Label(status.message, systemImage: status.systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(status.error ? Color.white : actionForeground)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(
                    status.error ? Color.red.opacity(0.92) : modalInk,
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .padding(16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var cardTransition: AnyTransition {
        Motion.transition(
            .asymmetric(
                insertion: .move(edge: direction > 0 ? .trailing : .leading),
                removal: .move(edge: direction > 0 ? .leading : .trailing)),
            reduceMotion: reduceMotion, preferCrossFade: false)
    }

    private func move(_ movement: Int) {
        direction = movement
        let destination = (index + movement + cards.count) % cards.count
        select(destination, direction: movement)
    }

    private func select(_ destination: Int, direction wantedDirection: Int? = nil) {
        guard destination != index else { return }
        direction = wantedDirection ?? (destination > index ? 1 : -1)
        withAnimation(Motion.animation(Motion.snap, reduceMotion: reduceMotion)) {
            index = destination
            copied = false
            status = nil
        }
    }

    private func loadPreviews() async {
        await Task.yield()
        for item in cards {
            guard !Task.isCancelled else { return }
            if let image = try? UsageShareRenderer.image(snapshot: snapshot, card: item, scale: 1) {
                previews[item] = image
            }
        }
    }

    private func copyImage() {
        do {
            let data = try UsageShareRenderer.pngData(snapshot: snapshot, card: card, scale: 2)
            try UsageShareDelivery.copy(data)
            withAnimation(Motion.animation(Motion.feedback, reduceMotion: reduceMotion)) {
                copied = true
            }
            showStatus("Image copied", systemImage: "checkmark.circle.fill")
        } catch {
            showStatus(
                error.localizedDescription, systemImage: "exclamationmark.triangle.fill",
                error: true)
        }
    }

    private func downloadImage() {
        let selectedCard = card
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = selectedCard.filenameStem + ".png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let data = try UsageShareRenderer.pngData(
                        snapshot: snapshot, card: selectedCard, scale: 2)
                    try UsageShareDelivery.write(data, to: url)
                    showStatus(
                        "Saved to \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                } catch {
                    showStatus(
                        error.localizedDescription, systemImage: "exclamationmark.triangle.fill",
                        error: true)
                }
            }
        }
    }

    private func showStatus(_ message: String, systemImage: String, error: Bool = false) {
        let identifier = UUID()
        statusID = identifier
        withAnimation(Motion.animation(Motion.feedback, reduceMotion: reduceMotion)) {
            status = UsageShareActionStatus(
                message: message, systemImage: systemImage, error: error)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard statusID == identifier else { return }
            withAnimation(Motion.animation(Motion.feedback, reduceMotion: reduceMotion)) {
                copied = false
                status = nil
            }
        }
    }
}

private struct ShareCarouselArrow: View {
    let systemImage: String
    let shortcut: KeyEquivalent
    let color: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(color.opacity(0.88))
                .frame(width: 48, height: 52)
                .background(
                    color.opacity(hovering ? 0.065 : 0),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(SharePressedButtonStyle())
        .keyboardShortcut(shortcut, modifiers: [])
        .onHover { hovering = $0 }
        .accessibilityLabel(systemImage == "chevron.left" ? "Previous card" : "Next card")
    }
}

private struct SharePressedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct UsageShareActionStatus: Equatable {
    let message: String
    let systemImage: String
    let error: Bool
}

enum UsageShareDeliveryError: LocalizedError {
    case copyFailed

    var errorDescription: String? { "the image could not be copied" }
}

enum UsageShareDelivery {
    static func copy(_ data: Data, to pasteboard: NSPasteboard = .general) throws {
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: .png) else {
            throw UsageShareDeliveryError.copyFailed
        }
    }

    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}
