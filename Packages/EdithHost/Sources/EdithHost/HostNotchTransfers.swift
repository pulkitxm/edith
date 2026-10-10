import AppKit
import Darwin
import Foundation

struct HostNotchTransferItem: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let addedAt: Date
    var position: CGPoint?
}

struct HostNotchPanelTransfer: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case share, drag }
    let id: UUID
    let displayID: UInt32
    let presentationID: UUID
    let kind: Kind
    let items: [HostNotchTransferItem]
    let fileURLs: [URL]
    var cancelled: Bool = false

    func validate(states: [HostNotchPanelState]) throws {
        guard let state = states.first(where: { $0.displayID == displayID }),
            state.presentationID == presentationID,
            cancelled || (state.visible && state.acceptsPointer),
            (1...32).contains(items.count), fileURLs.count == items.count,
            Set(items.map(\.id)).count == items.count,
            Set(fileURLs).count == fileURLs.count
        else { throw HostNotchPanelError.invalidState }
        let root = fileURLs[0].deletingLastPathComponent()
        guard Self.issuedDirectory(root) else { throw HostNotchPanelError.invalidState }
        for (item, url) in zip(items, fileURLs) {
            guard !item.name.isEmpty, item.name.utf8.count <= 255,
                item.name != ".", item.name != "..", !item.name.contains("/"),
                !item.name.utf8.contains(0),
                item.position.map({ $0.x.isFinite && $0.y.isFinite }) ?? true,
                url.isFileURL, url.host == nil || url.host == "localhost",
                url.query == nil, url.fragment == nil, url.path.utf8.count <= 4096,
                url.standardizedFileURL == url, url.deletingLastPathComponent() == root,
                url.lastPathComponent == item.name
            else { throw HostNotchPanelError.invalidState }
        }
    }

    static func issuedDirectory(_ url: URL) -> Bool {
        let prefix = "edith-shelf-incoming-"
        return url.isFileURL && url.path.hasPrefix("/") && url.query == nil && url.fragment == nil
            && url.standardizedFileURL == url && url.lastPathComponent.hasPrefix(prefix)
            && UUID(uuidString: String(url.lastPathComponent.dropFirst(prefix.count))) != nil
    }
}

struct HostNotchTransferAcknowledgement: Codable, Sendable {
    let identity: HostNotchPanelIdentity
    let id: UUID
    let opened: Bool
    let error: String?
}

struct HostNotchTransferFinish: Codable, Equatable, Sendable {
    let identity: HostNotchPanelIdentity
    let id: UUID
    let completed: Bool
    let outside: Bool
    let error: String?
}

@MainActor
protocol HostNotchNativeAction: AnyObject {
    func begin() throws
    func cancel() -> Bool
}

@MainActor
final class HostNotchTransferProxy {
    typealias Completion = @MainActor (Bool, Bool, String?) -> Void
    typealias Make =
        @MainActor (HostNotchPanelTransfer, HostNotchPanel, @escaping Completion) throws ->
        any HostNotchNativeAction
    private let invoke: HostNotchPanelCoordinator.Invoke
    private let make: Make
    private var active: Record?
    private var retired = false
    private var finishedIDs: [UUID] = []
    private(set) var failure: String?

    init(
        invoke: @escaping HostNotchPanelCoordinator.Invoke,
        make: @escaping Make = {
            HostNotchAppKitAction(transfer: $0, panel: $1, completion: $2)
        }
    ) { self.invoke = invoke; self.make = make }

    var pendingCount: Int { active == nil ? 0 : 1 }

    func accept(
        _ transfers: [HostNotchPanelTransfer], identity: HostNotchPanelIdentity,
        states: [HostNotchPanelState], panel: (UInt32) -> HostNotchPanel?
    ) throws {
        guard !retired, transfers.count <= 1,
            states.allSatisfy({ $0.ownershipID == identity.ownershipID })
        else { throw HostNotchPanelError.invalidState }
        for transfer in transfers { try transfer.validate(states: states) }
        if let active {
            if transfers.isEmpty, active.finish != nil { return }
            guard transfers.count == 1, transfers[0].id == active.transfer.id,
                identity == active.identity,
                transfers[0].items == active.transfer.items,
                transfers[0].fileURLs == active.transfer.fileURLs,
                transfers[0].displayID == active.transfer.displayID,
                transfers[0].presentationID == active.transfer.presentationID,
                transfers[0].kind == active.transfer.kind
            else { throw HostNotchPanelError.staleState }
            if transfers[0].cancelled { cancel(active) }
            return
        }
        guard let transfer = transfers.first, !finishedIDs.contains(transfer.id) else { return }
        guard let panel = panel(transfer.displayID) else { throw HostNotchPanelError.staleState }
        let record = try Record(identity: identity, transfer: transfer)
        active = record
        if transfer.cancelled {
            record.finish = .init(
                identity: identity, id: transfer.id, completed: false, outside: false, error: nil)
            finish(record); return
        }
        record.opening = Task { [weak self] in
            guard let self else { return }
            defer {
                record.opening = nil
                if record.cancelled { cancel(record) }
            }
            do {
                guard !record.cancelled, !retired else { throw CancellationError() }
                let action = try make(transfer, panel) {
                    [weak self, weak record = record] completed, outside, error in
                    guard let self, let record, active === record, record.finish == nil else {
                        return
                    }
                    record.finish = .init(
                        identity: identity, id: transfer.id,
                        completed: completed && !record.cancelled,
                        outside: outside && !record.cancelled,
                        error: error == nil ? nil : "The native shelf transfer did not complete.")
                    if record.opened { finish(record) }
                }
                record.action = action
                try record.pins.validate()
                try action.begin()
                let data = try JSONEncoder().encode(
                    HostNotchTransferAcknowledgement(
                        identity: identity, id: transfer.id, opened: true, error: nil))
                _ = try await invoke("notch.panel.transfer.ack", data, 5)
                record.opened = true
                if retired || record.cancelled { cancel(record) }
                if record.finish != nil { finish(record) }
            } catch {
                failure = "The native shelf transfer could not open."
                record.cancelled = true
                record.opened = true
                if record.action?.cancel() ?? true {
                    record.finish =
                        record.finish
                        ?? .init(
                            identity: identity, id: transfer.id, completed: false, outside: false,
                            error: "The native shelf transfer could not open.")
                    record.opened = true
                    finish(record)
                }
            }
        }
    }

    func cancelPending() {
        if let record = active { cancel(record) }
    }

    func stop() async throws {
        retired = true
        guard let record = active else { return }
        record.cancelled = true
        if let opening = record.opening { await opening.value }
        cancel(record)
        if let finishing = record.finishing { await finishing.value }
        if active != nil { throw HostNotchPanelError.staleState }
    }

    private func cancel(_ record: Record) {
        record.cancelled = true
        guard record.opening == nil else { return }
        if record.finish != nil { finish(record); return }
        if record.action?.cancel() ?? true {
            record.finish = .init(
                identity: record.identity, id: record.transfer.id, completed: false,
                outside: false, error: nil)
            record.opened = true
            finish(record)
        }
    }

    private func finish(_ record: Record) {
        guard record.finishing == nil, let request = record.finish else { return }
        record.finishing = Task { [weak self] in
            guard let self else { return }
            defer { record.finishing = nil }
            do {
                _ = try await invoke(
                    "notch.panel.transfer.finish", JSONEncoder().encode(request), 5)
                if active === record {
                    finishedIDs.append(record.transfer.id)
                    if finishedIDs.count > 32 { finishedIDs.removeFirst() }
                    active = nil; failure = nil
                }
            } catch { failure = "The native shelf transfer is still stopping." }
        }
    }

    private final class Record {
        let identity: HostNotchPanelIdentity
        let transfer: HostNotchPanelTransfer
        let pins: HostNotchIssuedFiles
        var action: (any HostNotchNativeAction)?
        var opening: Task<Void, Never>?
        var finishing: Task<Void, Never>?
        var finish: HostNotchTransferFinish?
        var opened = false
        var cancelled = false
        init(identity: HostNotchPanelIdentity, transfer: HostNotchPanelTransfer) throws {
            self.identity = identity; self.transfer = transfer
            pins = try HostNotchIssuedFiles(urls: transfer.fileURLs)
        }
    }
}

final class HostNotchIssuedFiles {
    private var descriptors: [(FileHandle, URL, dev_t, ino_t)] = []
    private let directory: FileHandle
    private let root: URL
    private let rootDevice: dev_t
    private let rootInode: ino_t
    init(urls: [URL], root issuedRoot: URL? = nil) throws {
        guard urls.count <= 32, let root = issuedRoot ?? urls.first?.deletingLastPathComponent(),
            HostNotchPanelTransfer.issuedDirectory(root)
        else { throw HostNotchPanelError.invalidState }
        let rootDescriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard rootDescriptor >= 0 else { throw HostNotchPanelError.invalidState }
        directory = FileHandle(fileDescriptor: rootDescriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(rootDescriptor, &info) == 0, info.st_uid == getuid(),
            info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o022 == 0
        else { throw HostNotchPanelError.invalidState }
        self.root = root; rootDevice = info.st_dev; rootInode = info.st_ino
        for url in urls {
            guard url.isFileURL, url.standardizedFileURL == url,
                url.deletingLastPathComponent() == root
            else { throw HostNotchPanelError.invalidState }
            let fd = openat(
                rootDescriptor, url.lastPathComponent,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw HostNotchPanelError.invalidState }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(),
                [S_IFREG, S_IFDIR].contains(info.st_mode & S_IFMT)
            else { throw HostNotchPanelError.invalidState }
            descriptors.append((handle, url, info.st_dev, info.st_ino))
        }
        try validate()
    }
    func validate() throws {
        var currentRoot = stat()
        guard lstat(root.path, &currentRoot) == 0, currentRoot.st_dev == rootDevice,
            currentRoot.st_ino == rootInode, currentRoot.st_mode & S_IFMT == S_IFDIR
        else { throw HostNotchPanelError.staleState }
        for (handle, url, device, inode) in descriptors {
            var pinned = stat(); var current = stat()
            guard fstat(handle.fileDescriptor, &pinned) == 0, lstat(url.path, &current) == 0,
                current.st_dev == device, current.st_ino == inode,
                pinned.st_dev == device, pinned.st_ino == inode
            else { throw HostNotchPanelError.staleState }
        }
    }
}

@MainActor
private final class HostNotchAppKitAction: NSObject, HostNotchNativeAction,
    @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate, NSDraggingSource
{
    private let transfer: HostNotchPanelTransfer
    private let panel: HostNotchPanel
    private let completion: HostNotchTransferProxy.Completion
    private var picker: NSSharingServicePicker?
    private var service: NSSharingService?
    private var dragging: NSDraggingSession?
    private var finished = false
    private var cancelled = false
    init(
        transfer: HostNotchPanelTransfer, panel: HostNotchPanel,
        completion: @escaping HostNotchTransferProxy.Completion
    ) {
        self.transfer = transfer; self.panel = panel; self.completion = completion
    }
    func begin() throws {
        guard panel.isVisible, let view = panel.contentView else {
            throw HostNotchPanelError.staleState
        }
        switch transfer.kind {
        case .share:
            let picker = NSSharingServicePicker(items: transfer.fileURLs)
            self.picker = picker; picker.delegate = self
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        case .drag:
            guard let event = panel.transferEvent,
                [.leftMouseDown, .leftMouseDragged].contains(event.type),
                event.window === panel,
                (0...2).contains(ProcessInfo.processInfo.systemUptime - event.timestamp)
            else {
                throw HostNotchPanelError.staleState
            }
            panel.transferEvent = nil
            let items = transfer.fileURLs.map { url in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                item.setDraggingFrame(
                    CGRect(
                        origin: view.convert(event.locationInWindow, from: nil),
                        size: CGSize(width: 32, height: 32)),
                    contents: NSWorkspace.shared.icon(forFile: url.path))
                return item
            }
            dragging = view.beginDraggingSession(with: items, event: event, source: self)
        }
    }
    func cancel() -> Bool {
        cancelled = true
        picker?.close()
        return finished || (service == nil && dragging == nil)
    }
    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        delegateFor sharingService: NSSharingService
    ) -> (any NSSharingServiceDelegate)? {
        self.service = sharingService; return self
    }
    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        if service == nil { end(completed: false, outside: false, error: nil) }
    }
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        end(completed: !cancelled, outside: false, error: nil)
    }
    func sharingService(
        _ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error
    ) {
        end(completed: false, outside: false, error: "The native sharing service did not complete.")
    }
    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        cancelled ? [] : .copy
    }
    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        end(
            completed: !operation.isEmpty && !cancelled,
            outside: !panel.frame.contains(screenPoint), error: nil)
    }
    private func end(completed: Bool, outside: Bool, error: String?) {
        guard !finished else { return }
        finished = true; picker?.delegate = nil; picker = nil; service = nil; dragging = nil
        completion(completed, outside, error)
    }
}
