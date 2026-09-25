import AppKit
import EdithKit
import SwiftUI
import WebKit

struct NotchBrowserPane<Leading: View>: View {
    var store: NotchBrowserStore
    @ViewBuilder var leading: Leading

    var body: some View {
        VStack(spacing: 0) {
            if store.showsSetup {
                HStack(spacing: 8) {
                    leading
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                NotchBrowserSetupView(store: store)
            } else {
                NotchBrowserTabStrip(store: store) { leading }
                NotchBrowserToolbar(store: store)
                content
            }
        }
        .overlay(alignment: .bottom) { NotchBrowserResizeHandles(store: store) }
        .onAppear { store.appeared() }
    }

    private var content: some View {
        BrowserWebViewHost(webView: store.selectedTab?.webView)
            .padding(.horizontal, NotchBrowserGeometry.contentInset)
            .padding(.bottom, NotchBrowserGeometry.contentInset)
            .overlay {
                if let dialog = store.dialog {
                    NotchBrowserDialogView(dialog: dialog)
                        .id(dialog.id)
                }
            }
            .overlay(alignment: .bottom) {
                if let toast = store.toast {
                    Text(toast)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(.black.opacity(0.8), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
                        .padding(.bottom, 22)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: store.toast)
    }
}

struct BrowserWebViewHost: NSViewRepresentable {
    let webView: WKWebView?

    func makeNSView(context: Context) -> BrowserWebContainerView {
        let container = BrowserWebContainerView()
        container.show(webView)
        return container
    }

    func updateNSView(_ container: BrowserWebContainerView, context: Context) {
        container.show(webView)
    }
}

final class BrowserWebContainerView: NSView {
    static let cornerRadius: CGFloat =
        NotchGeometry.expandedBottomRadius - NotchBrowserGeometry.contentInset

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        layer?.cornerRadius = Self.cornerRadius
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show(_ webView: WKWebView?) {
        if let webView, subviews.first === webView { return }
        for view in subviews where view !== webView { view.removeFromSuperview() }
        guard let webView else { return }
        webView.removeFromSuperview()
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }
}

struct NotchBrowserDialogView: View {
    let dialog: BrowserDialog
    @State private var text = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(alignment: .leading, spacing: 12) {
                Text(dialog.host.isEmpty ? "This page says" : "\(dialog.host) says")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                ScrollView {
                    Text(dialog.message)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
                if case .prompt = dialog.kind {
                    TextField("", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { dialog.resolve(true, text) }
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    if dialog.kind != .alert {
                        dialogButton("Cancel", primary: false) { dialog.resolve(false, nil) }
                    }
                    dialogButton("OK", primary: true) { dialog.resolve(true, text) }
                }
            }
            .padding(18)
            .frame(width: 380)
            .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
        }
        .onAppear {
            if case .prompt(let defaultText) = dialog.kind { text = defaultText }
        }
    }

    private func dialogButton(_ title: String, primary: Bool, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(primary ? Color.black : Color.white.opacity(0.85))
                .padding(.horizontal, 16)
                .frame(height: 28)
                .background(
                    primary ? Color.white.opacity(0.92) : Color.white.opacity(0.1), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.edith(.borderless))
        .keyboardShortcut(primary ? .defaultAction : .cancelAction)
    }
}

struct NotchBrowserResizeHandles: View {
    var store: NotchBrowserStore

    var body: some View {
        HStack(spacing: 0) {
            corner(.bottomLeading)
            Spacer(minLength: 0)
            Capsule()
                .fill(.white.opacity(store.isResizing ? 0.7 : 0.35))
                .frame(width: 46, height: 5)
                .frame(width: 140, height: 14)
                .contentShape(Rectangle())
                .gesture(resize(.bottom))
                .onHover { inside in
                    if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                }
                .help("Drag to resize the browser")
            Spacer(minLength: 0)
            corner(.bottomTrailing)
        }
        .frame(height: 14)
    }

    private func corner(_ edge: NotchBrowserResizeEdge) -> some View {
        Color.clear
            .frame(width: 26, height: 14)
            .contentShape(Rectangle())
            .gesture(resize(edge))
            .onHover { inside in
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
    }

    private func resize(_ edge: NotchBrowserResizeEdge) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { _ in
                if !store.isResizing { store.beginResize(edge) }
                store.updateResize()
            }
            .onEnded { _ in store.endResize() }
    }
}
