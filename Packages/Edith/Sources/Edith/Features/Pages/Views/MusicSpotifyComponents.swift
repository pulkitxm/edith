import AppKit
import EdithKit
import SwiftUI

struct SpotifyCollectionArtwork: View {
    let item: SpotifyCatalogItem
    var size: CGFloat = 150
    var fallbackSymbol = "music.note"
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        AsyncImage(url: item.artworkURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                LinearGradient(
                    colors: [
                        DashSkin.accent(scheme == .dark).opacity(0.28),
                        DashSkin.paper2(scheme == .dark),
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: fallbackSymbol)
                    .font(.system(size: UIScale.pt(size * 0.3), weight: .light))
                    .foregroundStyle(DashSkin.accent(scheme == .dark))
            }
        }
        .frame(width: UIScale.pt(size), height: UIScale.pt(size))
        .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(6)))
        .presenterCover(.music)
        .accessibilityHidden(true)
    }
}

struct SpotifyCollectionShelf: View {
    let title: String
    let items: [SpotifyCatalogItem]
    let onOpen: (SpotifyCatalogItem) -> Void
    let onPlay: (SpotifyCatalogItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            PageSectionHeader(title)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: UIScale.pt(12)) {
                    ForEach(items) { item in
                        SpotifyCollectionCard(item: item, onOpen: onOpen, onPlay: onPlay)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct SpotifyCollectionCard: View {
    let item: SpotifyCatalogItem
    let onOpen: (SpotifyCatalogItem) -> Void
    let onPlay: (SpotifyCatalogItem) -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            Button {
                onOpen(item)
            } label: {
                SpotifyCollectionArtwork(item: item)
            }
            .buttonStyle(.edith(.borderless))
            .accessibilityLabel("Open \(item.title)")
            .overlay(alignment: .bottomTrailing) {
                if item.playable {
                    Button {
                        onPlay(item)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.edithText(.body)).foregroundStyle(.white)
                            .frame(width: UIScale.pt(38), height: UIScale.pt(38))
                            .background(DashSkin.accent(scheme == .dark), in: Circle())
                    }
                    .buttonStyle(.edith(.borderless))
                    .padding(UIScale.pt(8))
                    .opacity(hovering ? 1 : 0.85)
                    .accessibilityLabel("Play \(item.title)")
                }
            }
            Button {
                onOpen(item)
            } label: {
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text(item.title).font(.edithText(.headline))
                        .foregroundStyle(.primary).lineLimit(2)
                    Text(item.subtitle).font(.edithText(.caption))
                        .foregroundStyle(.secondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .presenterBlur(.music)
            }
            .buttonStyle(.edith(.borderless))
        }
        .frame(width: UIScale.pt(150), alignment: .leading)
        .padding(UIScale.pt(8))
        .background(
            Color.primary.opacity(hovering ? 0.06 : 0),
            in: RoundedRectangle(cornerRadius: UIScale.pt(8))
        )
        .onHover { hovering = $0 }
    }
}

struct SpotifySongList: View {
    let items: [SpotifyCatalogItem]
    var currentURI: String? = nil
    let onPlay: (SpotifyCatalogItem) -> Void
    let onQueue: (SpotifyCatalogItem) -> Void
    let onSave: (SpotifyCatalogItem) -> Void
    var albumVisible = true
    var savedURIs: Set<String> = []
    var onPlayAtIndex: ((SpotifyCatalogItem, Int) -> Void)?
    @Environment(\.compactLayout) private var compact
    @State private var selectedURI: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: UIScale.pt(12)) {
                Text("#").frame(width: UIScale.pt(24))
                Text("Title").frame(maxWidth: .infinity, alignment: .leading)
                if albumVisible && !compact {
                    Text("Album").frame(maxWidth: .infinity, alignment: .leading)
                }
                Image(systemName: "clock").frame(width: UIScale.pt(44))
                Color.clear.frame(width: UIScale.pt(24), height: UIScale.pt(1))
            }
            .font(.edithText(.caption)).foregroundStyle(.secondary)
            .padding(.horizontal, UIScale.pt(12)).padding(.vertical, UIScale.pt(10))
            .accessibilityHidden(true)
            Divider()
            LazyVStack(spacing: UIScale.pt(2)) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    SpotifySongRow(
                        item: item, index: index + 1, current: currentURI == item.uri,
                        selected: selectedURI == item.uri, albumVisible: albumVisible && !compact,
                        saved: savedURIs.contains(item.uri),
                        onPlay: {
                            if let onPlayAtIndex {
                                onPlayAtIndex(item, index)
                            } else {
                                onPlay(item)
                            }
                        }, onQueue: { onQueue(item) },
                        onSave: { onSave(item) }, onSelect: { selectedURI = item.uri })
                }
            }
        }
    }
}

private struct SpotifySongRow: View {
    let item: SpotifyCatalogItem
    let index: Int
    let current: Bool
    let selected: Bool
    let albumVisible: Bool
    let saved: Bool
    let onPlay: () -> Void
    let onQueue: () -> Void
    let onSave: () -> Void
    let onSelect: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    private var accent: Color { DashSkin.accent(scheme == .dark) }
    private var duration: String {
        guard item.duration.isFinite, item.duration > 0 else { return "" }
        let seconds = Int(min(item.duration, Double(Int32.max)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        HStack(spacing: UIScale.pt(12)) {
            Button(action: onPlay) {
                Group {
                    if hovering {
                        Image(systemName: "play.fill")
                    } else if current {
                        Image(systemName: "waveform")
                    } else {
                        Text("\(index)").monospacedDigit()
                    }
                }
                .font(.edithText(.caption))
                .foregroundStyle(current ? accent : .secondary)
                .frame(width: UIScale.pt(24), height: UIScale.pt(32))
            }
            .buttonStyle(.edith(.borderless)).disabled(!item.playable)
            .accessibilityLabel("Play \(item.title)")
            Button {
                onSelect()
                if NSApp.currentEvent?.clickCount == 2 && item.playable { onPlay() }
            } label: {
                HStack(spacing: UIScale.pt(10)) {
                    SpotifyCollectionArtwork(item: item, size: 36)
                    VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                        Text(item.title).font(.edithText(.body)).fontWeight(.medium)
                            .foregroundStyle(current ? accent : .primary).lineLimit(1)
                        Text(item.subtitle).font(.edithText(.caption))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                    .presenterBlur(.music)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.edith(.borderless))
            .frame(maxWidth: .infinity, alignment: .leading)
            if albumVisible {
                Text(item.album ?? "").font(.edithText(.caption))
                    .foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .presenterBlur(.music)
            }
            Text(duration).font(.edithText(.caption)).monospacedDigit()
                .foregroundStyle(.secondary).frame(width: UIScale.pt(44), alignment: .trailing)
            Button(action: onSave) {
                Image(systemName: saved ? "heart.fill" : "heart").foregroundStyle(
                    saved ? accent : .secondary)
            }
            .buttonStyle(.edith(.borderless)).opacity(hovering || saved ? 1 : 0)
            .accessibilityLabel(saved ? "Remove from library" : "Save to library")
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis").font(.edithText(.body))
                    .frame(width: UIScale.pt(24), height: UIScale.pt(32))
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Actions for \(item.title)")
        }
        .padding(.horizontal, UIScale.pt(12)).padding(.vertical, UIScale.pt(8))
        .frame(minHeight: UIScale.pt(52))
        .background(
            current || selected ? accent.opacity(0.1) : Color.primary.opacity(hovering ? 0.05 : 0),
            in: RoundedRectangle(cornerRadius: UIScale.pt(6))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { actions }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected || current ? .isSelected : AccessibilityTraits())
        .accessibilityAction(named: Text("Play")) { if item.playable { onPlay() } }
    }

    @ViewBuilder private var actions: some View {
        Button("Play", systemImage: "play.fill", action: onPlay).disabled(!item.playable)
        Button("Add to queue", systemImage: "text.badge.plus", action: onQueue)
            .disabled(!item.playable)
        Button(
            saved ? "Remove from library" : "Save to library",
            systemImage: saved ? "heart.fill" : "heart", action: onSave)
    }
}
