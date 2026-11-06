import AppKit
import EdithExtensionUI
import EdithExtensionSupport
import SwiftUI

struct EmbeddedSpotifyCollectionArtwork: View {
    let item: EmbeddedSpotifyCatalogItem
    var size: CGFloat = 150
    var fallbackIcon = EdithIcon.music
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        EmbeddedMusicEngineImage(url: item.artworkURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                LinearGradient(
                    colors: [
                        DashSkin.accent(scheme == .dark).opacity(0.28),
                        DashSkin.paper2(scheme == .dark),
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                EdithIconView(fallbackIcon)
                    .font(.system(size: UIScale.pt(size * 0.3), weight: .light))
                    .foregroundStyle(DashSkin.accent(scheme == .dark))
            }
        }
        .frame(width: UIScale.pt(size), height: UIScale.pt(size))
        .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(6)))
        .presenterCover(EmbeddedMusicPrivacyState.shared.hides(.music))
        .accessibilityHidden(true)
    }
}

struct EmbeddedSpotifyCollectionShelf: View {
    let title: String
    let items: [EmbeddedSpotifyCatalogItem]
    let onOpen: (EmbeddedSpotifyCatalogItem) -> Void
    let onPlay: (EmbeddedSpotifyCatalogItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            PageSectionHeader(title)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: UIScale.pt(12)) {
                    ForEach(items) { item in
                        EmbeddedSpotifyCollectionCard(item: item, onOpen: onOpen, onPlay: onPlay)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct EmbeddedSpotifyCollectionCard: View {
    let item: EmbeddedSpotifyCatalogItem
    let onOpen: (EmbeddedSpotifyCatalogItem) -> Void
    let onPlay: (EmbeddedSpotifyCatalogItem) -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {
            onOpen(item)
        } label: {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                EmbeddedSpotifyCollectionArtwork(item: item)
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text(item.title).font(.edithText(.headline))
                        .foregroundStyle(.primary).lineLimit(2)
                    Text(item.subtitle).font(.edithText(.caption))
                        .foregroundStyle(.secondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .presenterBlur(EmbeddedMusicPrivacyState.shared.hides(.music))
            }
            .frame(width: UIScale.pt(150), alignment: .leading)
            .padding(UIScale.pt(8))
            .contentShape(Rectangle())
        }
        .buttonStyle(
            .edithShaped(
                RoundedRectangle(cornerRadius: UIScale.pt(8), style: .continuous), filled: true)
        )
        .accessibilityLabel("Open \(item.title)")
        .overlay(alignment: .topLeading) {
            if item.playable {
                Button {
                    onPlay(item)
                } label: {
                    EdithIconView(.play)
                        .font(.edithText(.body)).foregroundStyle(Color.themeOnAccent)
                        .frame(width: UIScale.pt(38), height: UIScale.pt(38))
                        .background(DashSkin.accent(scheme == .dark), in: Circle())
                }
                .buttonStyle(.edithShaped(Circle(), filled: true))
                .padding(UIScale.pt(8))
                .opacity(hovering ? 1 : 0.85)
                .accessibilityLabel("Play \(item.title)")
                .frame(
                    width: UIScale.pt(150), height: UIScale.pt(150), alignment: .bottomTrailing
                )
                .padding(UIScale.pt(8))
            }
        }
        .onHover { hovering = $0 }
    }
}

struct EmbeddedSpotifySongList: View {
    let items: [EmbeddedSpotifyCatalogItem]
    var currentURI: String? = nil
    let onPlay: (EmbeddedSpotifyCatalogItem) -> Void
    let onQueue: (EmbeddedSpotifyCatalogItem) -> Void
    let onSave: (EmbeddedSpotifyCatalogItem) -> Void
    var albumVisible = true
    var savedURIs: Set<String> = []
    var onPlayAtIndex: ((EmbeddedSpotifyCatalogItem, Int) -> Void)?
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
                EdithIconView(.clock).frame(width: UIScale.pt(44))
                Color.clear.frame(width: UIScale.pt(24), height: UIScale.pt(1))
            }
            .font(.edithText(.caption)).foregroundStyle(.secondary)
            .padding(.horizontal, UIScale.pt(12)).padding(.vertical, UIScale.pt(10))
            .accessibilityHidden(true)
            Divider()
            LazyVStack(spacing: UIScale.pt(2)) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    EmbeddedSpotifySongRow(
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

private struct EmbeddedSpotifySongRow: View {
    let item: EmbeddedSpotifyCatalogItem
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
        EdithRowButton {
            onSelect()
            if NSApp.currentEvent?.clickCount == 2 && item.playable { onPlay() }
        } label: {
            HStack(spacing: UIScale.pt(12)) {
                Color.clear.frame(width: UIScale.pt(24), height: UIScale.pt(32))
                HStack(spacing: UIScale.pt(10)) {
                    EmbeddedSpotifyCollectionArtwork(item: item, size: 36)
                    VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                        Text(item.title).font(.edithText(.body)).fontWeight(.medium)
                            .foregroundStyle(current ? accent : .primary).lineLimit(1)
                        Text(item.subtitle).font(.edithText(.caption))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                    .presenterBlur(EmbeddedMusicPrivacyState.shared.hides(.music))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if albumVisible {
                    Text(item.album ?? "").font(.edithText(.caption))
                        .foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .presenterBlur(EmbeddedMusicPrivacyState.shared.hides(.music))
                }
                Text(duration).font(.edithText(.caption)).monospacedDigit()
                    .foregroundStyle(.secondary).frame(width: UIScale.pt(44), alignment: .trailing)
            }
            .padding(.leading, UIScale.pt(Self.contentInset))
            .padding(.vertical, UIScale.pt(Self.verticalInset))
        } accessory: {
            HStack(spacing: UIScale.pt(12)) {
                Button(action: onSave) {
                    EdithIconView(.heart, tone: saved ? .duotone : .muted).foregroundStyle(
                        saved ? accent : .secondary)
                }
                .buttonStyle(.edith(.borderless)).opacity(hovering || saved ? 1 : 0)
                .accessibilityLabel(saved ? "Remove from library" : "Save to library")
                Menu {
                    actions
                } label: {
                    EdithIcon.more.image()
                }
                .borderlessMenu().fixedSize()
                .accessibilityLabel("Actions for \(item.title)")
            }
            .padding(.trailing, UIScale.pt(Self.contentInset))
        }
        .overlay(alignment: .leading) {
            Button(action: onPlay) {
                Group {
                    if hovering {
                        EdithIconView(.play)
                    } else if current {
                        EdithIconView(.waveform)
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
            .padding(.leading, UIScale.pt(Self.rowInset + Self.contentInset))
        }
        .background(
            current || selected ? accent.opacity(0.1) : .clear,
            in: RoundedRectangle(cornerRadius: UIScale.pt(Self.cornerRadius))
        )
        .onHover { hovering = $0 }
        .contextMenu { actions }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected || current ? .isSelected : AccessibilityTraits())
        .accessibilityAction(named: Text("Play")) { if item.playable { onPlay() } }
    }

    private static let rowInset = 9.0
    private static let contentInset = 3.0
    private static let verticalInset = 1.0
    private static let cornerRadius = 8.0

    @ViewBuilder private var actions: some View {
        Button("Play", edith: .play, action: onPlay).disabled(!item.playable)
        Button("Add to queue", edith: .textAdd, action: onQueue)
            .disabled(!item.playable)
        Button(action: onSave) {
            Label(
                saved ? "Remove from library" : "Save to library", edith: .heart,
                tone: saved ? .duotone : .muted)
        }
    }
}
