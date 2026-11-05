import AppKit
import EdithIcons
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

let outDir = CommandLine.arguments[1]

func save(_ image: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

struct Theme {
    let name: String
    let dark: Bool
    let paper: Color
    let accent: Color
}
func hex(_ s: String) -> Color {
    let v = UInt32(s.dropFirst(), radix: 16)!
    return Color(.sRGB, red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
}
let themes = [
    Theme(name: "dark", dark: true, paper: hex("#242426"), accent: hex("#e08a6a")),
    Theme(name: "light", dark: false, paper: hex("#ffffff"), accent: hex("#d97757")),
]

let titles: [EdithIcon: String] = [
    .appMaintenance: "App Updates", .attention: "Attention", .audioMixer: "Audio Mixer", .bifrost: "Launcher",
    .blitztree: "Disk Map", .calendar: "Calendar", .cleaner: "Cleaner", .clipboard: "Clipboard", .codeStats: "Code Stats",
    .colorPicker: "Color Picker", .companion: "Memory", .database: "Database", .docs: "Docs", .downloads: "Downloads",
    .emoji: "Emoji Picker", .focusDim: "Focus Dim", .herdr: "Agents", .hinge: "Hinge", .homebrew: "Homebrew", .jev: "Jev",
    .keepAwake: "Keep Awake", .keystrokeHighlight: "Keystroke", .latex: "LaTeX", .lidAwake: "Lid Awake", .machines: "Machines",
    .micMute: "Mic Mute", .music: "Music", .notchShelf: "Notch Shelf", .plugins: "Plugins", .presenter: "Presenter",
    .quinjet: "Code Review", .seoAudit: "Site Audit", .socialManager: "Social Manager", .studio: "Studio", .system: "Running Apps",
    .systemStats: "Menu Bar Stats", .terminal: "Terminal", .timeLapse: "Screen Recorder", .usage: "Usage",
    .virtualCamera: "Virtual Camera", .windowSweaters: "Window Sweaters",
    .suiteAgents: "Agents & Terminal", .suiteUtilities: "Mac Utilities", .suiteDesk: "Desk", .suiteMedia: "Media",
    .suiteDeveloper: "Developer & Data", .suiteLabs: "Labs", .workflowCustom: "Custom", .stepWorkflow: "Pick a workflow",
    .stepTools: "Choose your tools", .stepAccess: "Allow access", .permissionAccessibility: "Accessibility",
    .permissionApplicationAudio: "Application Audio", .permissionAutomation: "Automation", .permissionBluetooth: "Bluetooth",
    .permissionCamera: "Camera", .permissionFullDisk: "Full Disk Access", .permissionInputMonitoring: "Input Monitoring",
    .permissionNotifications: "Notifications", .permissionScreenRecording: "Screen Recording", .brand: "Edith",
]

struct Skin {
    let dark: Bool
    var paper: Color { hex(dark ? "#18181a" : "#f5f5f7") }
    var card: Color { hex(dark ? "#242426" : "#ffffff") }
    var ink: Color { hex(dark ? "#f5f5f7" : "#1d1d1f") }
    var soft: Color { hex(dark ? "#b0b0b5" : "#636366") }
    var faint: Color { hex(dark ? "#98989f" : "#76767b") }
    var line: Color { hex(dark ? "#363639" : "#e5e5ea") }
    var accent: Color { hex(dark ? "#e08a6a" : "#d97757") }
}

let suiteGroup: [EdithIcon] = [.suiteAgents, .suiteUtilities, .suiteDesk, .suiteMedia, .suiteDeveloper, .suiteLabs, .workflowCustom, .stepWorkflow, .stepTools, .stepAccess]
let permissionGroup: [EdithIcon] = EdithIcon.allCases.filter { $0.rawValue.hasPrefix("permission") }
let extensionGroup: [EdithIcon] = Array(titles.keys).filter { !suiteGroup.contains($0) && !permissionGroup.contains($0) && $0 != .brand }.sorted { $0.rawValue < $1.rawValue }
let controlGroup: [EdithIcon] = EdithIcon.allCases.filter { titles[$0] == nil }

struct SetCell: View {
    let icon: EdithIcon
    let skin: Skin
    let size: CGFloat
    var body: some View {
        VStack(spacing: 10) {
            EdithIconView(icon, size: size).foregroundStyle(skin.accent)
            Text(titles[icon] ?? icon.rawValue).font(.system(size: 11)).foregroundStyle(skin.soft)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(width: 112, height: size + 44)
    }
}

struct SetPanel: View {
    let skin: Skin
    func grid(_ title: String, _ icons: [EdithIcon], _ size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(skin.ink)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(112), spacing: 0), count: 7), alignment: .leading, spacing: 8) {
                ForEach(icons, id: \.self) { SetCell(icon: $0, skin: skin, size: size) }
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                EdithIconView(.brand, size: 40).foregroundStyle(skin.accent)
                Text("Edith icons").font(.system(size: 20, weight: .semibold)).foregroundStyle(skin.ink)
            }
            grid("Extensions", extensionGroup, 40)
            grid("Suites, workflows and onboarding", suiteGroup, 40)
            grid("Permissions", permissionGroup, 40)
            grid("Controls and objects", controlGroup, 40)
        }
        .padding(28)
        .background(skin.card)
    }
}

struct SizeLadder: View {
    let skin: Skin
    let list: [EdithIcon] = [.brand, .herdr, .usage, .cleaner, .hinge, .music, .calendar, .terminal, .suiteAgents, .permissionCamera]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach([16, 20, 24, 28, 32, 40, 64, 128] as [CGFloat], id: \.self) { size in
                HStack(alignment: .center, spacing: size > 60 ? 12 : 16) {
                    Text("\(Int(size))").font(.system(size: 11).monospacedDigit()).foregroundStyle(skin.faint).frame(width: 28, alignment: .trailing)
                    ForEach(size > 100 ? Array(list.prefix(6)) : list, id: \.self) { EdithIconView($0, size: size).foregroundStyle(skin.accent) }
                }
            }
        }
        .padding(24).background(skin.card)
    }
}

struct TintPanel: View {
    let list: [EdithIcon] = [.brand, .herdr, .usage, .bifrost, .clipboard, .studio, .music, .calendar, .terminal, .keepAwake]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array([("#e08a6a", "#242426"), ("#0a84ff", "#1b2130"), ("#30d158", "#1a2620"), ("#ff375f", "#2a1c21"), ("#40c8e0", "#1a2628"), ("#f5f5f7", "#242426")].enumerated()), id: \.offset) { _, pair in
                HStack(spacing: 18) { ForEach(list, id: \.self) { EdithIconView($0, size: 40).foregroundStyle(hex(pair.0)) } }
                    .padding(.horizontal, 24).padding(.vertical, 12).background(hex(pair.1))
            }
            ForEach(Array([("#d97757", "#ffffff"), ("#007aff", "#f4f7fb"), ("#1d1d1f", "#ffffff")].enumerated()), id: \.offset) { _, pair in
                HStack(spacing: 18) { ForEach(list, id: \.self) { EdithIconView($0, size: 40).foregroundStyle(hex(pair.0)) } }
                    .padding(.horizontal, 24).padding(.vertical, 12).background(hex(pair.1))
            }
            HStack(spacing: 18) { ForEach(list, id: \.self) { EdithIconView($0, size: 40, tone: .monochrome).foregroundStyle(hex("#f5f5f7")) } }
                .padding(.horizontal, 24).padding(.vertical, 12).background(hex("#242426"))
        }
    }
}

struct WelcomeMock: View {
    let skin: Skin
    func step(_ new: EdithIcon, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            EdithIconView(new, size: 24).foregroundStyle(skin.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(skin.ink)
                Text(detail).font(.system(size: 12)).foregroundStyle(skin.soft).lineLimit(2, reservesSpace: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11).background(RoundedRectangle(cornerRadius: 10).strokeBorder(skin.line))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                EdithIconView(.brand, size: 60).foregroundStyle(skin.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Edith").font(.system(size: 17, weight: .semibold)).foregroundStyle(skin.ink)
                    Text("Small, native tools for your Mac. Pick only the ones you need.").font(.system(size: 13)).foregroundStyle(skin.soft)
                }
            }
            Text("Setup takes about a minute").font(.system(size: 13, weight: .semibold)).foregroundStyle(skin.ink)
            HStack(spacing: 10) {
                step(.stepWorkflow, "Pick a workflow", "Tell Edith what you do.")
                step(.stepTools, "Choose your tools", "Add or remove any later.")
                step(.stepAccess, "Allow what they need", "Approve permissions once.")
            }
        }
        .padding(22).frame(width: 760).background(skin.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct MarketCard: View {
    let skin: Skin
    let icon: EdithIcon
    let title: String
    let tagline: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                EdithIconView(icon, size: 40).foregroundStyle(skin.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(skin.ink)
                    Text(tagline).font(.system(size: 12)).foregroundStyle(skin.soft).lineLimit(2, reservesSpace: true)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Text("1.8 MB").font(.system(size: 11)).foregroundStyle(skin.faint)
                Spacer()
                Text("Get").font(.system(size: 12, weight: .medium)).foregroundStyle(skin.ink)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(skin.line))
            }
        }
        .padding(14).frame(width: 300).background(skin.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct MarketMock: View {
    let skin: Skin
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                MarketCard(skin: skin, icon: .usage, title: "Usage", tagline: "See what your coding agents cost and how close you are to their limits.")
                MarketCard(skin: skin, icon: .herdr, title: "Agents", tagline: "See every coding agent in one board, and step in when one needs you.")
            }
            HStack(spacing: 10) {
                MarketCard(skin: skin, icon: .bifrost, title: "Launcher", tagline: "Open apps, do quick math and find files from one bar.")
                MarketCard(skin: skin, icon: .clipboard, title: "Clipboard", tagline: "Everything you copy, searchable and one shortcut away.")
            }
            HStack(spacing: 10) {
                MarketCard(skin: skin, icon: .cleaner, title: "Cleaner", tagline: "Get back disk space from caches and leftovers, safely.")
                MarketCard(skin: skin, icon: .hinge, title: "Hinge", tagline: "Fold your desktop as you close the lid.")
            }
        }
    }
}

struct SuiteMock: View {
    let skin: Skin
    func card(_ icon: EdithIcon, _ title: String, _ count: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                EdithIconView(icon, size: 32).foregroundStyle(skin.accent)
                Spacer()
                Text(count).font(.system(size: 11)).foregroundStyle(skin.faint)
            }
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(skin.ink).lineLimit(1)
        }
        .padding(12).frame(width: 150).background(skin.card).clipShape(RoundedRectangle(cornerRadius: 12))
    }
    func header(_ icon: EdithIcon, _ title: String) -> some View {
        HStack(spacing: 8) {
            EdithIconView(icon, size: 20).foregroundStyle(skin.soft)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(skin.ink)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                card(.suiteAgents, "Agents & Terminal", "9 tools")
                card(.suiteUtilities, "Mac Utilities", "11 tools")
                card(.suiteDesk, "Desk", "7 tools")
            }
            HStack(spacing: 10) {
                card(.suiteMedia, "Media", "6 tools")
                card(.suiteDeveloper, "Developer & Data", "5 tools")
                card(.workflowCustom, "Custom", "")
            }
            HStack(spacing: 22) {
                header(.suiteAgents, "Agents & Terminal")
                header(.suiteUtilities, "Mac Utilities")
                header(.suiteLabs, "Labs")
            }
        }
    }
}

struct Themed<Content: View>: View {
    let content: (Skin) -> Content
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            content(Skin(dark: true)).padding(20).background(Skin(dark: true).paper)
            content(Skin(dark: false)).padding(20).background(Skin(dark: false).paper)
        }
    }
}

@MainActor
func sheet<V: View>(_ view: V, _ path: String, scale: CGFloat = 2) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    save(renderer.cgImage!, path)
}

struct TextRow: View {
    let icon: EdithIcon
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            EdithIconView(icon)
            Text(icon.rawValue).lineLimit(1)
        }
        .frame(width: 150, alignment: .leading)
    }
}

struct TextPanel: View {
    let skin: Skin
    let icons: [EdithIcon]
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(150), spacing: 4), count: 5), alignment: .leading, spacing: 6) {
            ForEach(icons, id: \.self) { TextRow(icon: $0) }
        }
        .font(.system(size: 13))
        .foregroundStyle(skin.ink)
        .padding(14)
        .background(skin.card)
    }
}

struct FontLadder: View {
    let skin: Skin
    let sizes: [CGFloat] = [10, 11, 12, 13, 14, 15, 17, 20, 22, 26, 34]
    let icons: [EdithIcon] = [.plus, .close, .check, .chevronRight, .trash, .search, .refresh, .gear, .folder, .more]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(sizes, id: \.self) { size in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(size))pt Save").frame(width: 170, alignment: .leading)
                    ForEach(icons, id: \.self) { EdithIconView($0) }
                    Text("Hxg")
                }
                .font(.system(size: size))
            }
        }
        .foregroundStyle(skin.ink).padding(14).background(skin.card)
    }
}

struct StatePanel: View {
    let skin: Skin
    @ViewBuilder var row: some View {
        Label("Rename", edith: .edit)
        Label("Delete", edith: .trash).foregroundStyle(.red)
        Label("Refresh", edith: .refresh).font(.caption)
        Label("Open in window", edith: .external).font(.title3)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row
            Divider()
            HStack(spacing: 8) { Text(edith: .warning).foregroundColor(.orange); Text("\(Text(edith: .warning).foregroundColor(.orange)) inline text icon") }
            HStack(spacing: 10) {
                EdithIconView(.heart); EdithIconView(.heart, tone: .muted); EdithIconView(.pin, tone: .muted); EdithIconView(.pin)
                EdithIconView(.usage); EdithIconView(.usage, tone: .monochrome); EdithIconView(.usage, tone: .muted)
                EdithIcon.plus.image().foregroundStyle(skin.accent); EdithIcon.usage.image().foregroundStyle(skin.accent)
            }
            HStack(spacing: 8) {
                Text("selected"); EdithIconView(.folder); EdithIconView(.chevronRight)
            }
            .padding(6).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 5)).foregroundStyle(.white)
            EdithIconView(.check).font(.system(size: 20)).imageScale(.small)
            EdithIconView(.check).font(.system(size: 13)).imageScale(.large)
        }
        .font(.system(size: 13)).foregroundStyle(skin.ink).padding(14).frame(width: 330, alignment: .leading).background(skin.card)
    }
}

struct NativeControls: View {
    let skin: Skin
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Save", edith: .saveTo) {}
            Button("Disabled", edith: .saveTo) {}.disabled(true)
            Button("Prominent", edith: .check) {}.buttonStyle(.borderedProminent).tint(skin.accent)
            Button("Plain row", edith: .trash) {}.buttonStyle(.plain)
            Button("Plain disabled", edith: .trash) {}.buttonStyle(.plain).disabled(true)
            Button {} label: { EdithIconView(.more) }.buttonStyle(.plain).disabled(true)
            Toggle(isOn: .constant(true)) { Label("Toggle label", edith: .bell) }
            Picker("Picker", selection: .constant(1)) {
                Label("First", edith: .folder).tag(1)
                Label("Second", edith: .doc).tag(2)
            }
            TabView {
                Text("Tab").tabItem { Label("Tab", edith: .home) }
            }
            .frame(height: 70)
            List(selection: .constant(Set([1]))) {
                Label("Selected row", edith: .folder).tag(1)
                Label("Other row", edith: .doc).tag(2)
            }
            .frame(height: 70)
        }
        .font(.system(size: 13)).padding(14).frame(width: 300).background(skin.card)
        .environment(\.colorScheme, skin.dark ? .dark : .light)
    }
}

@MainActor
func hosted<V: View>(_ view: V, dark: Bool, _ path: String) {
    let host = NSHostingView(rootView: view)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let size = host.fittingSize
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: true)
    window.appearance = host.appearance
    window.contentView = host
    host.frame = CGRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    if let image = bitmap.cgImage { save(image, path) }
}

@MainActor
func raster<V: View>(_ view: V, scale: CGFloat) -> CGImage {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    return renderer.cgImage!
}

struct ZoomCell: View {
    let icon: EdithIcon
    let skin: Skin
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(icon.rawValue).font(.system(size: 9)).foregroundStyle(skin.faint).lineLimit(1)
            HStack(spacing: 5) {
                pixels(16, 1, 3); pixels(20, 1, 3); pixels(16, 2, 1.5); pixels(20, 2, 1.5)
            }
        }
        .frame(width: 214, alignment: .leading)
    }
    func pixels(_ size: CGFloat, _ scale: CGFloat, _ zoom: CGFloat) -> some View {
        let image = raster(EdithIconView(icon, size: size).foregroundStyle(skin.accent).background(skin.card), scale: scale)
        return Image(decorative: image, scale: 1).interpolation(.none).resizable()
            .frame(width: size * scale * zoom, height: size * scale * zoom)
    }
}

struct SmallSizes: View {
    let skin: Skin
    var icons = EdithIcon.allCases
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(214), spacing: 4), count: 8), alignment: .leading, spacing: 6) {
            ForEach(icons, id: \.self) { ZoomCell(icon: $0, skin: skin) }
        }
        .padding(14).background(skin.card)
    }
}

@MainActor
func confusablePairs() -> String {
    let icons = EdithIcon.allCases
    func alpha(_ icon: EdithIcon) -> [UInt8] {
        let image = raster(EdithIconView(icon, size: 16).foregroundStyle(.white).background(.black), scale: 1)
        var data = [UInt8](repeating: 0, count: 256)
        let context = CGContext(data: &data, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        return data
    }
    let pixels = icons.map(alpha)
    var pairs: [(Double, String)] = []
    for a in pixels.indices {
        for b in pixels.indices where b > a {
            var best = Double.infinity
            for dx in -1...1 {
                for dy in -1...1 {
                    var total = 0
                    for y in 0..<16 {
                        for x in 0..<16 {
                            total += abs(Int(pixels[a][((y + dy + 16) % 16) * 16 + (x + dx + 16) % 16]) - Int(pixels[b][y * 16 + x]))
                        }
                    }
                    best = min(best, Double(total) / (256 * 255))
                }
            }
            pairs.append((best, "\(icons[a].rawValue) \(icons[b].rawValue)"))
        }
    }
    pairs.sort { $0.0 < $1.0 }
    return pairs.prefix(24).map { String(format: "%.3f %@", $0.0, $0.1) }.joined(separator: "\n")
}

@MainActor
func sheets() {
    let dark = Skin(dark: true), light = Skin(dark: false)
    sheet(HStack(alignment: .top, spacing: 0) { SetPanel(skin: dark); SetPanel(skin: light) }, "\(outDir)/full-set.png")
    sheet(VStack(spacing: 0) { SmallSizes(skin: dark); SmallSizes(skin: light) }, "\(outDir)/small-sizes.png")
    sheet(HStack(spacing: 0) { SizeLadder(skin: dark); SizeLadder(skin: light) }, "\(outDir)/size-ladder.png")
    sheet(TintPanel(), "\(outDir)/tints.png")
    let halves = stride(from: 0, to: controlGroup.count, by: 100).map { Array(controlGroup[$0..<min($0 + 100, controlGroup.count)]) }
    for (index, icons) in halves.enumerated() {
        sheet(HStack(alignment: .top, spacing: 0) { TextPanel(skin: dark, icons: icons).environment(\.colorScheme, .dark); TextPanel(skin: light, icons: icons).environment(\.colorScheme, .light) }, "\(outDir)/text-13pt-\(index + 1)-2x.png")
        sheet(TextPanel(skin: dark, icons: icons).environment(\.colorScheme, .dark), "\(outDir)/text-13pt-\(index + 1)-1x.png", scale: 1)
    }
    sheet(HStack(alignment: .top, spacing: 0) { FontLadder(skin: dark); StatePanel(skin: dark).environment(\.colorScheme, .dark) }, "\(outDir)/text-context-dark.png")
    sheet(HStack(alignment: .top, spacing: 0) { FontLadder(skin: light); StatePanel(skin: light).environment(\.colorScheme, .light) }, "\(outDir)/text-context-light.png")
    sheet(Themed { WelcomeMock(skin: $0) }, "\(outDir)/mock-welcome.png")
    sheet(Themed { MarketMock(skin: $0) }, "\(outDir)/mock-marketplace.png")
    sheet(Themed { SuiteMock(skin: $0) }, "\(outDir)/mock-suite-row.png")
    hosted(NativeControls(skin: dark), dark: true, "\(outDir)/text-native-dark.png")
    hosted(NativeControls(skin: light), dark: false, "\(outDir)/text-native-light.png")
    let report = confusablePairs()
    try? report.write(toFile: "\(outDir)/confusable-16pt.txt", atomically: true, encoding: .utf8)
    print(report.split(separator: "\n").prefix(8).joined(separator: "\n"))
}

MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.prohibited)
    if CommandLine.arguments.count > 2 {
        let icons = CommandLine.arguments[2].split(separator: ",").map { EdithIcon(name: String($0)) }
        sheet(VStack(spacing: 0) { SmallSizes(skin: Skin(dark: true), icons: icons); SmallSizes(skin: Skin(dark: false), icons: icons) }, "\(outDir)/focus.png", scale: 3)
    } else {
        sheets()
    }
}
