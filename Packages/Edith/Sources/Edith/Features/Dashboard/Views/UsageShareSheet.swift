import AppKit
import EdithKit
import SwiftUI
import UniformTypeIdentifiers

struct UsageShareSheet: View {
    let snapshot: UsageShareSnapshot

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var direction = 1
    @State private var previews: [UsageShareCard: NSImage] = [:]
    @State private var status: UsageShareActionStatus?
    @State private var statusID = UUID()

    private var dark: Bool { scheme == .dark }
    private var cards: [UsageShareCard] { UsageShareCard.allCases }
    private var card: UsageShareCard { cards[index] }

    var body: some View {
        VStack(spacing: UIScale.pt(20)) {
            header
            carousel
            pagination
            actionBar
        }
        .padding(UIScale.pt(28))
        .frame(minWidth: UIScale.pt(780), minHeight: UIScale.pt(690))
        .background(sheetBackground)
        .task { await loadPreviews() }
        .onKeyPress(.leftArrow) {
            move(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            move(1)
            return .handled
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                Text("Share your agent story")
                    .font(DashSkin.serif(28))
                    .foregroundStyle(DashSkin.ink(dark))
                Text("A polished snapshot made from your local usage data.")
                    .font(.system(size: UIScale.pt(13)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: UIScale.pt(12), weight: .semibold))
                    .frame(width: UIScale.pt(28), height: UIScale.pt(28))
            }
            .buttonStyle(.edith(.secondary))
            .accessibilityLabel("Close share cards")
            .keyboardShortcut(.cancelAction)
        }
    }

    private var carousel: some View {
        HStack(spacing: UIScale.pt(16)) {
            carouselButton(systemImage: "chevron.left", movement: -1)
            ZStack {
                RoundedRectangle(cornerRadius: UIScale.pt(24), style: .continuous)
                    .fill(DashSkin.paper2(dark))
                if let image = previews[card] {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(3 / 2, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(22)))
                        .id(card)
                        .transition(cardTransition)
                } else {
                    ProgressView("Preparing your cards…")
                        .controlSize(.small)
                        .foregroundStyle(DashSkin.inkSoft(dark))
                }
            }
            .frame(width: UIScale.pt(640), height: UIScale.pt(427))
            .shadow(color: .black.opacity(dark ? 0.42 : 0.18), radius: 22, y: 12)
            .gesture(
                DragGesture(minimumDistance: UIScale.pt(18))
                    .onEnded { gesture in
                        guard abs(gesture.translation.width) > UIScale.pt(50) else { return }
                        move(gesture.translation.width < 0 ? 1 : -1)
                    })
            carouselButton(systemImage: "chevron.right", movement: 1)
        }
        .frame(maxWidth: .infinity)
    }

    private var pagination: some View {
        HStack(spacing: UIScale.pt(12)) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { item in
                Button { select(item.offset) } label: {
                    Circle()
                        .fill(
                            item.offset == index
                                ? DashSkin.accent(dark) : DashSkin.inkFaint(dark).opacity(0.32)
                        )
                        .frame(
                            width: UIScale.pt(item.offset == index ? 8 : 6),
                            height: UIScale.pt(item.offset == index ? 8 : 6))
                        .frame(width: UIScale.pt(16), height: UIScale.pt(16))
                }
                .buttonStyle(.plain)
                .help(item.element.title)
                .accessibilityLabel(item.element.title)
                .accessibilityAddTraits(item.offset == index ? .isSelected : [])
            }
            Text(card.title)
                .font(.system(size: UIScale.pt(12), weight: .medium))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .contentTransition(.interpolate)
        }
        .animation(Motion.animation(Motion.feedback, reduceMotion: reduceMotion), value: index)
    }

    private var actionBar: some View {
        HStack(spacing: UIScale.pt(10)) {
            if let status {
                Label(status.message, systemImage: status.systemImage)
                    .font(.system(size: UIScale.pt(12), weight: .medium))
                    .foregroundStyle(status.error ? Color.red : DashSkin.sage)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            Spacer()
            Button(action: copyImage) {
                Label("Copy image", systemImage: "doc.on.doc")
            }
            .buttonStyle(.edith(.primary, tint: DashSkin.accent(dark)))
            .keyboardShortcut("c", modifiers: [.command, .shift])
            Button(action: downloadImage) {
                Label("Download PNG", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(.edith(.secondary, tint: DashSkin.accent(dark)))
        }
        .frame(height: UIScale.pt(36))
        .animation(Motion.animation(Motion.feedback, reduceMotion: reduceMotion), value: status)
    }

    private var sheetBackground: some View {
        DashSkin.paper(dark)
            .overlay(alignment: .topTrailing) {
                RadialGradient(
                    colors: [DashSkin.accent(dark).opacity(0.12), .clear],
                    center: .topTrailing, startRadius: 0, endRadius: UIScale.pt(420))
            }
            .ignoresSafeArea()
    }

    private var cardTransition: AnyTransition {
        Motion.transition(
            .asymmetric(
                insertion: .move(edge: direction > 0 ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: direction > 0 ? .leading : .trailing).combined(with: .opacity)),
            reduceMotion: reduceMotion, preferCrossFade: false)
    }

    private func carouselButton(systemImage: String, movement: Int) -> some View {
        Button { move(movement) } label: {
            Image(systemName: systemImage)
                .font(.system(size: UIScale.pt(15), weight: .semibold))
                .frame(width: UIScale.pt(34), height: UIScale.pt(44))
        }
        .buttonStyle(.edith(.secondary))
        .accessibilityLabel(movement < 0 ? "Previous card" : "Next card")
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
            showStatus("Image copied", systemImage: "checkmark.circle.fill")
        } catch {
            showStatus(error.localizedDescription, systemImage: "exclamationmark.triangle.fill", error: true)
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
                    showStatus("Saved to \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
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
                status = nil
            }
        }
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
