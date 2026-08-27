import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import EdithKit
import Foundation

@MainActor
final class FinderToolsService {
    private var shortcuts: FinderShortcutService?
    private var installer: DiskImageAppInstaller?

    init() {
        syncSettings()
    }

    func syncSettings() {
        let defaults = SharedDefaults.store
        let keyboardWanted =
            FinderToolsSupport.enabled(
                AppStorageKeys.FinderTools.cutPaste, defaults: defaults)
            || FinderToolsSupport.enabled(AppStorageKeys.FinderTools.rename, defaults: defaults)
            || FinderToolsSupport.enabled(
                AppStorageKeys.FinderTools.pasteImages, defaults: defaults)
        if keyboardWanted, shortcuts == nil { shortcuts = FinderShortcutService() }
        if !keyboardWanted {
            shortcuts?.shutdown()
            shortcuts = nil
        }
        shortcuts?.syncSettings()

        let installerWanted = FinderToolsSupport.enabled(
            AppStorageKeys.FinderTools.diskImageInstaller, defaults: defaults)
        if installerWanted, installer == nil { installer = DiskImageAppInstaller() }
        if !installerWanted {
            installer?.shutdown()
            installer = nil
        }
    }

    func shutdown() {
        shortcuts?.shutdown()
        shortcuts = nil
        installer?.shutdown()
        installer = nil
    }
}

private final class FinderShortcutService: @unchecked Sendable {
    private enum Route {
        case pass
        case swallow
        case rename
    }

    private enum Key {
        static let x: Int64 = 7
        static let c: Int64 = 8
        static let v: Int64 = 9
        static let f2: Int64 = 120
        static let enter: Int64 = 36
    }

    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var stopping = false
    private var cutURLs: [URL] = []
    private var cutChangeCount = 0
    private var moving = false
    private var savingImage = false
    private var cutPasteEnabled = true
    private var renameEnabled = true
    private var pasteImagesEnabled = true
    private static let finderID = "com.apple.finder"
    private static let maxImageBytes = 64 * 1_024 * 1_024

    init() {
        syncSettings()
    }

    func syncSettings() {
        dispatchPrecondition(condition: .onQueue(.main))
        cutPasteEnabled = FinderToolsSupport.enabled(AppStorageKeys.FinderTools.cutPaste)
        renameEnabled = FinderToolsSupport.enabled(AppStorageKeys.FinderTools.rename)
        pasteImagesEnabled = FinderToolsSupport.enabled(AppStorageKeys.FinderTools.pasteImages)
        if AXIsProcessTrusted(), cutPasteEnabled || renameEnabled || pasteImagesEnabled {
            start()
        } else {
            stop()
        }
        if !cutPasteEnabled { clearCut() }
    }

    func shutdown() {
        dispatchPrecondition(condition: .onQueue(.main))
        stop()
        clearCut()
    }

    private func start() {
        let newThread = lock.withLock { () -> Thread? in
            guard thread == nil else { return nil }
            stopping = false
            let value = Thread { [weak self] in self?.runTap() }
            value.name = "Edith Finder Tools"
            value.qualityOfService = .userInteractive
            thread = value
            return value
        }
        newThread?.start()
    }

    private func stop() {
        let snapshot = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in
            stopping = true
            return (tap, runLoop)
        }
        if let tap = snapshot.0 { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop = snapshot.1 {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                CFRunLoopStop(runLoop)
            }
            CFRunLoopWakeUp(runLoop)
        }
    }

    private func runTap() {
        autoreleasepool {
            let currentRunLoop = CFRunLoopGetCurrent()
            lock.withLock { runLoop = currentRunLoop }
            guard !lock.withLock({ stopping }) else {
                clearTapState()
                return
            }
            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            guard
                let eventTap = CGEvent.tapCreate(
                    tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                    eventsOfInterest: mask,
                    callback: { _, type, event, context in
                        guard let context else { return Unmanaged.passUnretained(event) }
                        let service = Unmanaged<FinderShortcutService>.fromOpaque(context)
                            .takeUnretainedValue()
                        return service.route(type: type, event: event)
                    }, userInfo: Unmanaged.passUnretained(self).toOpaque())
            else {
                clearTapState()
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            lock.withLock { tap = eventTap }
            CFRunLoopAddSource(currentRunLoop, source, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
            if !lock.withLock({ stopping }) { CFRunLoopRun() }
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFRunLoopRemoveSource(currentRunLoop, source, .commonModes)
            CFMachPortInvalidate(eventTap)
            clearTapState()
        }
    }

    private func clearTapState() {
        lock.withLock {
            tap = nil
            runLoop = nil
            thread = nil
            stopping = false
        }
    }

    private func route(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = lock.withLock({ stopping ? nil : tap }) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let commandCandidate =
            flags.contains(.maskCommand)
            && !flags.contains(.maskControl) && !flags.contains(.maskAlternate)
            && !flags.contains(.maskShift)
            && (keyCode == Key.x || keyCode == Key.c || keyCode == Key.v)
        let renameCandidate =
            keyCode == Key.f2
            && !flags.contains(.maskCommand) && !flags.contains(.maskControl)
            && !flags.contains(.maskAlternate) && !flags.contains(.maskShift)
        guard commandCandidate || renameCandidate else { return Unmanaged.passUnretained(event) }

        var result = Route.pass
        DispatchQueue.main.sync { result = handle(keyCode: keyCode) }
        switch result {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        case .rename:
            guard let replacement = event.copy() else { return Unmanaged.passUnretained(event) }
            replacement.setIntegerValueField(.keyboardEventKeycode, value: Key.enter)
            replacement.flags = []
            return Unmanaged.passRetained(replacement)
        }
    }

    private func handle(keyCode: Int64) -> Route {
        guard AXIsProcessTrusted(),
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.finderID,
            !focusedElementIsEditable()
        else { return .pass }
        switch keyCode {
        case Key.f2:
            return renameEnabled ? .rename : .pass
        case Key.x:
            guard cutPasteEnabled else { return .pass }
            captureCut()
            return .swallow
        case Key.c:
            if cutPasteEnabled { clearCut() }
            return .pass
        case Key.v:
            if cutPasteEnabled, !cutURLs.isEmpty {
                guard NSPasteboard.general.changeCount == cutChangeCount else {
                    clearCut()
                    return imagePasteRoute()
                }
                guard !moving else { return .swallow }
                moveCutFiles()
                return .swallow
            }
            return imagePasteRoute()
        default:
            return .pass
        }
    }

    private func imagePasteRoute() -> Route {
        guard pasteImagesEnabled, !savingImage,
            FinderToolsSupport.preferredImageType(
                in: (NSPasteboard.general.types ?? []).map(\.rawValue)) != nil
        else { return .pass }
        saveClipboardImage()
        return .swallow
    }

    private func captureCut() {
        FinderToolsBridge.selection { [weak self] urls in
            guard let self else { return }
            DispatchQueue.main.async {
                guard !urls.isEmpty else {
                    self.clearCut()
                    NSSound.beep()
                    return
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects(urls as [NSURL])
                self.cutURLs = urls
                self.cutChangeCount = pasteboard.changeCount
            }
        }
    }

    private func moveCutFiles() {
        moving = true
        let sources = cutURLs
        FinderToolsBridge.insertionLocation { [weak self] directory in
            guard let self else { return }
            guard let directory else {
                DispatchQueue.main.async { self.finishMove(failed: true) }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let fileManager = FileManager.default
                let destinations = sources.compactMap {
                    FinderToolsSupport.moveDestination(
                        for: $0, in: directory, fileExists: fileManager.fileExists(atPath:))
                }
                guard destinations.count == sources.count,
                    Set(destinations.map(\.path)).count == destinations.count
                else {
                    DispatchQueue.main.async { self.finishMove(failed: true) }
                    return
                }
                var failed = false
                for (source, destination) in zip(sources, destinations) {
                    if destination == source { continue }
                    do {
                        try fileManager.moveItem(at: source, to: destination)
                    } catch {
                        failed = true
                    }
                }
                DispatchQueue.main.async { self.finishMove(failed: failed) }
            }
        }
    }

    private func finishMove(failed: Bool) {
        moving = false
        clearCut()
        if failed { NSSound.beep() }
    }

    private func saveClipboardImage() {
        savingImage = true
        let pasteboard = NSPasteboard.general
        let identifiers = (pasteboard.types ?? []).map(\.rawValue)
        guard let type = FinderToolsSupport.preferredImageType(in: identifiers),
            let source = pasteboard.data(forType: NSPasteboard.PasteboardType(type.rawValue)),
            source.count <= Self.maxImageBytes,
            let representation = NSBitmapImageRep(data: source),
            let png = type == .png
                ? source : representation.representation(using: .png, properties: [:]),
            png.count <= Self.maxImageBytes
        else {
            savingImage = false
            NSSound.beep()
            return
        }
        FinderToolsBridge.insertionLocation { [weak self] directory in
            guard let self else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                guard let directory else {
                    DispatchQueue.main.async { self.finishImageSave(failed: true) }
                    return
                }
                let manager = FileManager.default
                let name = FinderToolsSupport.imageFileName(at: Date())
                let destination = FinderToolsSupport.uniqueImageURL(
                    named: name, in: directory, fileExists: manager.fileExists(atPath:))
                do {
                    try png.write(to: destination, options: [.atomic, .withoutOverwriting])
                    DispatchQueue.main.async { self.finishImageSave(failed: false) }
                } catch {
                    DispatchQueue.main.async { self.finishImageSave(failed: true) }
                }
            }
        }
    }

    private func finishImageSave(failed: Bool) {
        savingImage = false
        if failed { NSSound.beep() }
    }

    private func clearCut() {
        cutURLs = []
        cutChangeCount = 0
    }

    private func focusedElementIsEditable() -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var focused: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return false }
        let element = focused as! AXUIElement
        var role: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
            let role = role as? String
        else { return false }
        return ["AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField"].contains(role)
    }
}

private enum FinderToolsBridge {
    private static let queue = DispatchQueue(label: "com.pulkit.edith.finder-tools")

    static func selection(_ completion: @escaping @Sendable ([URL]) -> Void) {
        queue.async {
            let source = """
                tell application id "com.apple.finder"
                    set paths to {}
                    repeat with itemReference in (get selection)
                        set end of paths to POSIX path of (itemReference as alias)
                    end repeat
                    return paths
                end tell
                """
            guard let descriptor = execute(source) else {
                completion([])
                return
            }
            let values = (0..<descriptor.numberOfItems).compactMap {
                descriptor.atIndex($0 + 1)?.stringValue
            }
            completion(values.map { URL(fileURLWithPath: $0) })
        }
    }

    static func insertionLocation(_ completion: @escaping @Sendable (URL?) -> Void) {
        queue.async {
            let source = """
                tell application id "com.apple.finder"
                    return POSIX path of (insertion location as alias)
                end tell
                """
            let path = execute(source)?.stringValue
            completion(path.map { URL(fileURLWithPath: $0, isDirectory: true) })
        }
    }

    private static func execute(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let descriptor = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? descriptor : nil
    }
}

@MainActor
private final class DiskImageAppInstaller {
    private struct Candidate: Sendable {
        let mount: URL
        let application: URL
        let image: URL
        let imageIdentity: FileIdentity
        let destination: URL
        let name: String
    }

    private struct FileIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    private enum Outcome: Sendable {
        case installed
        case installedKeepingMount
        case installedKeepingImage
        case failed(String)
    }

    private struct CommandResult: Sendable {
        let status: Int32
        let output: Data
    }

    private let queue = DispatchQueue(label: "com.pulkit.edith.disk-image-installer", qos: .utility)
    private var observer: NSObjectProtocol?
    private var pending: [Candidate] = []
    private var activeMounts = Set<String>()
    private var prompting = false

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let mount = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            else {
                return
            }
            MainActor.assumeIsolated { self?.inspect(mount) }
        }
    }

    func shutdown() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        pending = []
        activeMounts = []
    }

    private func inspect(_ mount: URL) {
        guard observer != nil else { return }
        let path = mount.standardizedFileURL.resolvingSymlinksInPath().path
        guard activeMounts.insert(path).inserted else { return }
        queue.async { [weak self] in
            let candidate = Self.candidate(mountedAt: mount)
            DispatchQueue.main.async {
                guard let self else { return }
                self.activeMounts.remove(path)
                guard self.observer != nil, let candidate else { return }
                self.pending.append(candidate)
                self.presentNext()
            }
        }
    }

    private func presentNext() {
        guard !prompting, observer != nil, let candidate = pending.first else { return }
        pending.removeFirst()
        prompting = true
        let alert = NSAlert()
        alert.messageText = "Install \(candidate.name)?"
        alert.informativeText =
            "Edith found one verified app on this disk image. Install it in Applications, eject the image, and move the DMG to Trash?"
        alert.icon = NSWorkspace.shared.icon(forFile: candidate.application.path)
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            prompting = false
            presentNext()
            return
        }
        queue.async { [weak self] in
            let outcome = Self.install(candidate)
            DispatchQueue.main.async {
                self?.present(outcome, candidate: candidate)
                self?.prompting = false
                self?.presentNext()
            }
        }
    }

    private func present(_ outcome: Outcome, candidate: Candidate) {
        let alert = NSAlert()
        alert.icon = NSWorkspace.shared.icon(forFile: candidate.destination.path)
        switch outcome {
        case .installed:
            alert.messageText = "\(candidate.name) Installed"
            alert.informativeText =
                "The app is in Applications. The disk image was ejected and its DMG moved to Trash."
        case .installedKeepingMount:
            alert.alertStyle = .warning
            alert.messageText = "\(candidate.name) Installed"
            alert.informativeText =
                "The app is in Applications, but macOS could not eject the disk image. The DMG was left in place."
        case .installedKeepingImage:
            alert.alertStyle = .warning
            alert.messageText = "\(candidate.name) Installed"
            alert.informativeText =
                "The app is in Applications and the disk image was ejected, but the DMG could not be moved to Trash."
        case let .failed(message):
            alert.alertStyle = .warning
            alert.messageText = "Could Not Install \(candidate.name)"
            alert.informativeText = message
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    nonisolated private static func candidate(mountedAt mount: URL) -> Candidate? {
        let manager = FileManager.default
        let info = run("/usr/bin/hdiutil", ["info", "-plist"])
        guard info.status == 0,
            let image = FinderToolsSupport.diskImageURL(
                mountedAt: mount, hdiutilInfo: info.output),
            let identity = fileIdentity(image),
            let entries = try? manager.contentsOfDirectory(
                at: mount, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])
        else { return nil }
        let applications = entries.filter { url in
            guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                ),
                values.isDirectory == true, values.isSymbolicLink != true
            else { return false }
            return validApplication(url)
        }
        guard applications.count == 1, let application = applications.first,
            let destination = FinderToolsSupport.applicationDestination(
                for: application,
                applicationsDirectory: URL(fileURLWithPath: "/Applications", isDirectory: true)),
            !manager.fileExists(atPath: destination.path)
        else { return nil }
        let preferred =
            Bundle(url: application)?.object(
                forInfoDictionaryKey: "CFBundleDisplayName") as? String
        return Candidate(
            mount: mount, application: application, image: image, imageIdentity: identity,
            destination: destination,
            name: FinderToolsSupport.displayName(preferred: preferred, application: application))
    }

    nonisolated private static func install(_ candidate: Candidate) -> Outcome {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: candidate.destination.path) else {
            return .failed(
                "An app with this name already exists in Applications. Edith did not replace it.")
        }
        let staging: URL
        do {
            staging = try manager.url(
                for: .itemReplacementDirectory, in: .userDomainMask,
                appropriateFor: candidate.destination.deletingLastPathComponent(), create: true)
        } catch {
            return .failed("A secure staging folder could not be created.")
        }
        defer { try? manager.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(candidate.application.lastPathComponent)
        let copied = run(
            "/usr/bin/ditto",
            ["--rsrc", "--extattr", "--acl", "--qtn", candidate.application.path, staged.path])
        guard copied.status == 0, validApplication(staged) else {
            return .failed("The app could not be copied from the disk image.")
        }
        guard gatekeeperAccepts(staged) else {
            return .failed("macOS could not verify this app, so Edith left it on the disk image.")
        }
        do {
            guard !manager.fileExists(atPath: candidate.destination.path) else {
                return .failed("An app with this name appeared in Applications during the install.")
            }
            try manager.moveItem(at: staged, to: candidate.destination)
        } catch {
            return .failed("The verified app could not be placed in Applications.")
        }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: candidate.mount)
        } catch {
            return .installedKeepingMount
        }
        guard fileIdentity(candidate.image) == candidate.imageIdentity else {
            return .installedKeepingImage
        }
        do {
            try manager.trashItem(at: candidate.image, resultingItemURL: nil)
            return .installed
        } catch {
            return .installedKeepingImage
        }
    }

    nonisolated private static func validApplication(_ url: URL) -> Bool {
        guard let bundle = Bundle(url: url), let executable = bundle.executableURL,
            FileManager.default.isExecutableFile(atPath: executable.path)
        else { return false }
        let root = url.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return executable.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root)
    }

    nonisolated private static func gatekeeperAccepts(_ url: URL) -> Bool {
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", url.path]).status == 0
        else { return false }
        let status = run("/usr/sbin/spctl", ["--status"])
        if String(data: status.output, encoding: .utf8)?.localizedCaseInsensitiveContains(
            "disabled") == true
        {
            return true
        }
        return run("/usr/sbin/spctl", ["-a", "-t", "exec", url.path]).status == 0
    }

    nonisolated private static func fileIdentity(_ url: URL) -> FileIdentity? {
        var value = stat()
        guard url.path.withCString({ lstat($0, &value) }) == 0,
            value.st_mode & S_IFMT == S_IFREG
        else { return nil }
        return FileIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino))
    }

    nonisolated private static func run(_ executable: String, _ arguments: [String])
        -> CommandResult
    {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: Data())
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: data)
    }
}
