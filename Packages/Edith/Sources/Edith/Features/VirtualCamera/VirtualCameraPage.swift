import AVFoundation
import EdithKit
import SwiftUI

struct VirtualCameraPageAttachment {
    private(set) var acquired = false
    private var visible = false

    mutating func begin() { visible = true }

    @MainActor mutating func acquire(_ model: VirtualCameraPageModel) {
        guard visible, !acquired else { return }
        acquired = true
        model.appear()
    }

    @MainActor mutating func release(_ model: VirtualCameraPageModel) {
        visible = false
        guard acquired else { return }
        acquired = false
        model.disappear()
    }
}

struct VirtualCameraPage: View {
    @StateObject private var model: VirtualCameraPageModel
    @State private var attachment = VirtualCameraPageAttachment()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    init(model: VirtualCameraPageModel? = nil) {
        _model = StateObject(wrappedValue: model ?? VirtualCameraPageModel.shared)
    }

    private var dark: Bool { scheme == .dark }
    private var sceneBinding: Binding<String> {
        Binding(
            get: { model.state.activeSceneID?.uuidString ?? "" },
            set: { raw in
                guard let id = UUID(uuidString: raw),
                    let scene = model.state.scenes.first(where: { $0.id == id })
                else { return }
                model.apply(scene)
            })
    }

    private func sceneIsValid(_ raw: String) -> Bool {
        guard let id = UUID(uuidString: raw) else { return false }
        return model.state.scenes.contains { $0.id == id }
    }

    var body: some View {
        PageScaffold(pinnedHeader: true) {
            PageHeader(
                "Virtual Camera",
                trailing: { VirtualCameraHeaderControls(model: model, dark: dark) })
        } content: {
            PageColumns {
                VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    VirtualCameraStage(model: model, dark: dark)
                    VirtualCameraMeetingControls(model: model, dark: dark)
                    VirtualCameraToolbar(model: model, dark: dark)
                    VirtualCameraSceneStrip(model: model, dark: dark)
                }
                .frame(minWidth: UIScale.pt(0), maxWidth: .infinity, alignment: .topLeading)
                VirtualCameraInspector(model: model, dark: dark)
                    .frame(width: compact ? nil : UIScale.pt(340))
                    .frame(maxWidth: compact ? .infinity : nil, alignment: .topLeading)
            }
        }
        .navigationRoute("inspector", selection: $model.tab)
        .navigationRoute("scene", selection: sceneBinding, isValid: sceneIsValid)
        .pageTask(cancel: { attachment.release(model) }) {
            attachment.begin()
            await Task.yield()
            guard !Task.isCancelled else { return }
            attachment.acquire(model)
        }
        .alert(
            "Virtual Camera",
            isPresented: Binding(
                get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct VirtualCameraHeaderControls: View {
    @ObservedObject var model: VirtualCameraPageModel
    let dark: Bool

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            VirtualCameraStatusPill(model: model, dark: dark)
            if model.state.privacy == .live {
                Menu {
                    ForEach(
                        [VirtualCameraPrivacy.stopped, .card, .blank, .freeze], id: \.self
                    ) { mode in
                        Button(mode.title) { model.pause(mode) }
                    }
                } label: {
                    Label("Pause", systemImage: "pause.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Hide the camera from apps without leaving the call (⌃⌥⌘V by default)")
            } else {
                Button {
                    model.resume()
                } label: {
                    Label("Go live", systemImage: "play.circle.fill")
                }
                .buttonStyle(.edith(.primary))
                .help("Show the live camera again")
            }
        }
    }
}

struct VirtualCameraStatusPill: View {
    @ObservedObject var model: VirtualCameraPageModel
    let dark: Bool

    private var tint: Color {
        if model.state.privacy != .live { return DashSkin.warn }
        if model.isLive { return DashSkin.danger }
        return DashSkin.inkFaint(dark)
    }

    var body: some View {
        HStack(spacing: UIScale.pt(6)) {
            Circle()
                .fill(tint)
                .frame(width: UIScale.pt(8), height: UIScale.pt(8))
            Text(model.statusHeadline)
                .font(.system(size: UIScale.pt(12), weight: .medium))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .lineLimit(1)
        }
        .padding(.horizontal, UIScale.pt(10))
        .padding(.vertical, UIScale.pt(5))
        .background(Capsule().fill(DashSkin.paper2(dark)))
        .overlay(Capsule().stroke(DashSkin.line(dark)))
        .frame(maxWidth: UIScale.pt(220))
        .help(model.statusHeadline)
        .accessibilityElement(children: .combine)
    }
}

struct VirtualCameraStage: View {
    @ObservedObject var model: VirtualCameraPageModel
    let dark: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: UIScale.pt(14), style: .continuous)
                .fill(Color.black)
            if model.state.privacy != .stopped,
                model.cameraAccess == .authorized || model.hasPreviewFrame
            {
                VirtualCameraPreview(
                    display: model.display, mirrored: model.state.mirrorPreview,
                    covered: PresenterState.shared.hides(.camera),
                    onPan: { model.pan(by: $0, in: $1) },
                    onZoom: { model.zoom(by: $0, anchor: $1) },
                    onReset: { model.resetFraming() }
                )
                .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(14), style: .continuous))
            }
            if model.state.privacy == .stopped {
                VStack(spacing: UIScale.pt(12)) {
                    Image(systemName: "video.slash")
                        .font(.system(size: UIScale.pt(32)))
                    Text("Camera stopped")
                        .font(.system(size: UIScale.pt(18), weight: .semibold))
                    Text("Capture, preview and output are off. Choose Go live to resume.")
                        .font(.system(size: UIScale.pt(12)))
                }
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, UIScale.pt(16))
            } else if model.hasNoCameraSource {
                VStack(spacing: UIScale.pt(12)) {
                    Image(systemName: "video.slash")
                        .font(.system(size: UIScale.pt(32)))
                    Text("No camera connected")
                        .font(.system(size: UIScale.pt(18), weight: .semibold))
                    Text("Connect a camera, then refresh the camera list.")
                        .font(.system(size: UIScale.pt(12)))
                    Button("Refresh cameras") { model.refreshSources() }
                        .buttonStyle(.edith(.secondary))
                }
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, UIScale.pt(16))
            } else if let failure = model.previewFailure {
                VStack(spacing: UIScale.pt(12)) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: UIScale.pt(28)))
                    Text("Camera preview unavailable")
                        .font(.system(size: UIScale.pt(16), weight: .semibold))
                    Text(failure)
                        .font(.system(size: UIScale.pt(12)))
                    Button("Retry camera") { model.retryPreview() }
                        .buttonStyle(.edith(.secondary))
                }
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(UIScale.pt(16))
            } else if let title = model.previewLoadingTitle {
                LoadingContainer(state: .loading) {
                    EmptyView()
                } placeholder: {
                    LoadingIndicator(title).foregroundStyle(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.cameraAccess != .authorized && !model.hasPreviewFrame {
                VirtualCameraAccessPrompt(model: model)
            }
            if PresenterState.shared.hides(.camera), model.state.privacy != .stopped {
                Color.black
                    .overlay {
                        Label("Hidden in Presenter Mode", systemImage: "lock.fill")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .allowsHitTesting(false)
            }
            if model.showsGrid, model.state.privacy != .stopped {
                VirtualCameraThirdsGrid()
                    .allowsHitTesting(false)
            }
            if model.state.privacy != .stopped && model.hasPreviewFrame {
                VStack {
                    HStack(spacing: UIScale.pt(6)) {
                        VirtualCameraBadge(
                            text: model.isLive ? "LIVE" : "PREVIEW",
                            tint: model.isLive ? DashSkin.danger : Color.white.opacity(0.25))
                        if model.state.privacy != .live {
                            VirtualCameraBadge(
                                text: model.state.privacy.title.uppercased(), tint: DashSkin.warn)
                        }
                        Spacer()
                        if model.composition.framing.autoFrame != .off {
                            VirtualCameraBadge(text: "AUTO FRAME", tint: Color.white.opacity(0.25))
                        }
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        Text(String(format: "%.1fx", model.composition.framing.zoom))
                            .font(DashSkin.mono(12, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, UIScale.pt(8))
                            .padding(.vertical, UIScale.pt(4))
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                    }
                }
                .padding(UIScale.pt(12))
                .allowsHitTesting(false)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(14), style: .continuous))
        .help("Drag to move the picture. Command-scroll or pinch to zoom. Double-click to reset.")
    }
}

struct VirtualCameraBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: UIScale.pt(10), weight: .bold))
            .tracking(0.6)
            .foregroundStyle(.white)
            .padding(.horizontal, UIScale.pt(7))
            .padding(.vertical, UIScale.pt(3))
            .background(Capsule().fill(tint))
    }
}

struct VirtualCameraThirdsGrid: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                    path.move(to: CGPoint(x: proxy.size.width * fraction, y: 0))
                    path.addLine(to: CGPoint(x: proxy.size.width * fraction, y: proxy.size.height))
                    path.move(to: CGPoint(x: 0, y: proxy.size.height * fraction))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height * fraction))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 1)
        }
    }
}

struct VirtualCameraAccessPrompt: View {
    @ObservedObject var model: VirtualCameraPageModel

    var body: some View {
        VStack(spacing: UIScale.pt(10)) {
            Image(systemName: "web.camera")
                .font(.system(size: UIScale.pt(30)))
                .foregroundStyle(.white.opacity(0.8))
            Text(
                model.cameraAccess == .notDetermined
                    ? "Edith needs your camera" : "Camera access is off"
            )
            .font(.system(size: UIScale.pt(15), weight: .semibold))
            .foregroundStyle(.white)
            Text("Allow camera access to see the preview and frame your shot.")
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(.white.opacity(0.7))
            Button(model.cameraAccess == .notDetermined ? "Allow camera" : "Open System Settings") {
                model.requestCameraAccess()
            }
            .buttonStyle(.edith(.primary))
        }
        .multilineTextAlignment(.center)
        .padding()
    }
}

struct VirtualCameraToolbar: View {
    @ObservedObject var model: VirtualCameraPageModel
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            HStack(spacing: UIScale.pt(10)) {
                Menu {
                    ForEach(model.sources) { source in
                        Button {
                            model.selectSource(source)
                        } label: {
                            Label(source.name, systemImage: source.symbolName)
                        }
                    }
                    Divider()
                    Button("Refresh cameras") { model.refreshSources() }
                } label: {
                    Label(
                        model.state.media.kind == .camera
                            ? model.selectedSource?.name
                                ?? (model.sourcesLoaded ? "No camera" : "Finding cameras")
                            : model.state.media.kind == .video ? "Video file" : "Screen or window",
                        systemImage: model.state.media.kind == .camera
                            ? model.selectedSource?.symbolName ?? "video.slash"
                            : model.state.media.kind == .video ? "film" : "display")
                }
                .menuStyle(.borderlessButton)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: UIScale.pt(180), alignment: .leading)
                .help("Choose the camera Edith frames")
            }
            HStack(spacing: UIScale.pt(10)) {
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(DashSkin.inkFaint(dark))
                Slider(
                    value: Binding(
                        get: { model.composition.framing.zoom }, set: { model.setZoom($0) }),
                    in: VirtualCameraFraming.zoomRange
                )
                .frame(minWidth: UIScale.pt(60))
                .accessibilityLabel("Zoom")
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(DashSkin.inkFaint(dark))
                Text(String(format: "%.1fx", model.composition.framing.zoom))
                    .font(DashSkin.mono(12))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .frame(width: UIScale.pt(40), alignment: .trailing)
            }
            HStack(spacing: UIScale.pt(10)) {
                toolButton("rotate.left", "Rotate left") { model.rotate(clockwise: false) }
                toolButton("rotate.right", "Rotate right") { model.rotate(clockwise: true) }
                toolButton(
                    "arrow.left.and.right.righttriangle.left.righttriangle.right",
                    "Flip horizontally"
                ) {
                    model.updateComposition { $0.framing.flipHorizontal.toggle() }
                }
                toolButton(model.showsGrid ? "grid.circle.fill" : "grid", "Show the thirds grid") {
                    model.showsGrid.toggle()
                }
                toolButton("arrow.counterclockwise", "Reset the framing") { model.resetFraming() }
            }
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(8))
        .edithSurface(cornerRadius: 12)
    }

    private func toolButton(_ symbol: String, _ help: String, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.edith(.iconOnly))
        .help(help)
        .accessibilityLabel(help)
    }
}

struct VirtualCameraSceneStrip: View {
    @ObservedObject var model: VirtualCameraPageModel
    let dark: Bool
    @State private var naming = false
    @State private var newName = ""
    @State private var renaming: VirtualCameraScene?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            HStack {
                Text("Scenes")
                    .font(.system(size: UIScale.pt(13), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Text("Switch with ⌘1 to ⌘9 or ed camera scene apply")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(1)
                Spacer()
                if let active = model.state.activeScene, model.state.activeSceneIsModified {
                    Button(
                        PresenterState.shared.hides(.camera)
                            ? "Update scene" : "Update \(active.name)"
                    ) { model.updateScene(active) }
                    .buttonStyle(.edith(.borderless))
                }
                Button {
                    newName = model.suggestedSceneName()
                    naming = true
                } label: {
                    Label("Save scene", systemImage: "plus")
                }
                .buttonStyle(.edith(.secondary))
                .popover(isPresented: $naming, arrowEdge: .bottom) {
                    VirtualCameraNamePrompt(
                        title: "Save the current look as a scene", text: $newName,
                        confirm: "Save"
                    ) {
                        model.saveScene(named: newName)
                        naming = false
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: UIScale.pt(8)) {
                    ForEach(Array(model.state.scenes.enumerated()), id: \.element.id) {
                        index, scene in
                        sceneButton(scene, index: index)
                    }
                }
                .padding(.vertical, UIScale.pt(2))
            }
        }
        .padding(UIScale.pt(12))
        .edithSurface(cornerRadius: 12)
        .popover(item: $renaming) { scene in
            VirtualCameraNamePrompt(
                title: PresenterState.shared.hides(.camera)
                    ? "Rename scene" : "Rename \(scene.name)",
                text: $renameText, confirm: "Rename"
            ) {
                model.renameScene(scene, to: renameText)
                renaming = nil
            }
        }
    }

    @ViewBuilder
    private func sceneButton(_ scene: VirtualCameraScene, index: Int) -> some View {
        let active = model.state.activeSceneID == scene.id
        let button = Button {
            model.apply(scene)
        } label: {
            HStack(spacing: UIScale.pt(6)) {
                if index < 9 {
                    Text("\(index + 1)")
                        .font(DashSkin.mono(10, weight: .semibold))
                        .foregroundStyle(active ? DashSkin.accent(dark) : DashSkin.inkFaint(dark))
                }
                Text(scene.name)
                    .font(.system(size: UIScale.pt(12), weight: active ? .semibold : .regular))
                    .presenterBlur(.camera)
                if active, model.state.activeSceneIsModified {
                    Circle().fill(DashSkin.warn).frame(width: UIScale.pt(6), height: UIScale.pt(6))
                        .help("Changed since you applied it")
                }
            }
        }
        .buttonStyle(.edith(.selection))
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(8))
                .stroke(active ? DashSkin.accent(dark) : Color.clear, lineWidth: 1.5)
        )
        .contextMenu {
            Button("Update with the current look") { model.updateScene(scene) }
            Button("Rename…") {
                renameText = scene.name
                renaming = scene
            }
            Button("Duplicate") { model.duplicateScene(scene) }
            Divider()
            Button("Move left") { model.moveScene(scene, by: -1) }
            Button("Move right") { model.moveScene(scene, by: 1) }
            Divider()
            Button("Delete", role: .destructive) { model.deleteScene(scene) }
        }
        if index < 9 {
            button.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        } else {
            button
        }
    }
}

struct VirtualCameraNamePrompt: View {
    let title: String
    @Binding var text: String
    let confirm: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            Text(title)
                .font(.system(size: UIScale.pt(13), weight: .semibold))
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: UIScale.pt(240))
                .onSubmit(action)
            HStack {
                Spacer()
                Button(confirm, action: action)
                    .buttonStyle(.edith(.primary))
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(UIScale.pt(14))
    }
}
