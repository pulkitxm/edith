import AppKit
import CoreGraphics
import EdithKit
import IOKit.graphics

@MainActor
final class DisplayBrightnessController {
    private struct GammaTable {
        let red: [CGGammaValue]
        let green: [CGGammaValue]
        let blue: [CGGammaValue]
        let count: UInt32
        let fingerprint: String
    }

    private struct Route {
        let method: DisplayBrightnessMethod
        let service: CFTypeRef?
        let maximum: UInt16
    }

    private(set) var displays: [DisplayPowerDisplay] = []
    private var routes: [UInt32: Route] = [:]
    private var gammaTables: [UInt32: GammaTable] = [:]
    private var dimmed = Set<UInt32>()
    private var screenObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private let changed: () -> Void

    init(changed: @escaping () -> Void) {
        self.changed = changed
    }

    func start() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    func refresh() {
        let levels = DisplayPowerOperationExecution.brightnessLevels()
        var nextDisplays: [DisplayPowerDisplay] = []
        var nextRoutes: [UInt32: Route] = [:]
        var external: [(UInt32, String)] = []

        for screen in NSScreen.screens {
            guard let id = screen.displayPowerID, CGDisplayMirrorsDisplay(id) == 0 else { continue }
            let builtIn = CGDisplayIsBuiltin(id) != 0
            var brightness: Float = -1
            if DisplayBrightnessBridge.getBrightness?(id, &brightness) == 0,
                (0...1).contains(brightness)
            {
                let value = levels[id] ?? Double(brightness)
                nextDisplays.append(
                    DisplayPowerDisplay(
                        id: id, name: screen.localizedName, builtIn: builtIn,
                        method: .system, brightness: value))
                nextRoutes[id] = Route(method: .system, service: nil, maximum: 100)
            } else if builtIn {
                nextDisplays.append(
                    DisplayPowerDisplay(
                        id: id, name: screen.localizedName, builtIn: true,
                        method: .unavailable, brightness: 1))
            } else {
                external.append((id, screen.localizedName))
            }
        }

        let services = DisplayBrightnessBridge.externalServices()
        if external.count == 1, services.count == 1 {
            let (id, name) = external[0]
            let service = services[0]
            if let reading = ddcRead(service: service) {
                let maximum = max(reading.maximum, 1)
                let value = levels[id] ?? Double(reading.current) / Double(maximum)
                nextDisplays.append(
                    DisplayPowerDisplay(
                        id: id, name: name, builtIn: false, method: .ddc,
                        brightness: value))
                nextRoutes[id] = Route(method: .ddc, service: service, maximum: maximum)
                external.removeAll()
            }
        }

        for (id, name) in external {
            captureGamma(for: id)
            let value = levels[id] ?? (dimmed.contains(id) ? currentBrightness(id) : 1)
            nextDisplays.append(
                DisplayPowerDisplay(
                    id: id, name: name, builtIn: false,
                    method: gammaTables[id] == nil ? .unavailable : .software,
                    brightness: value))
            if gammaTables[id] != nil {
                nextRoutes[id] = Route(method: .software, service: nil, maximum: 100)
            }
        }

        routes = nextRoutes
        displays = nextDisplays.sorted { left, right in
            if left.builtIn != right.builtIn { return left.builtIn }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        applyConfiguredLevels()
        changed()
    }

    func applyConfiguredLevels() {
        let levels = DisplayPowerOperationExecution.brightnessLevels()
        var updated = displays
        for index in updated.indices {
            let id = updated[index].id
            guard let value = levels[id], let route = routes[id] else { continue }
            let normalized = DisplayPowerPolicy.normalizedBrightness(value)
            switch route.method {
            case .system:
                _ = DisplayBrightnessBridge.setBrightness?(id, Float(normalized))
            case .ddc:
                if let service = route.service {
                    _ = ddcWrite(
                        service: service,
                        value: DisplayPowerPolicy.deviceBrightness(
                            normalized, maximum: route.maximum))
                }
            case .software:
                _ = applyGamma(normalized, to: id)
            case .unavailable:
                break
            }
            updated[index] = DisplayPowerDisplay(
                id: id, name: updated[index].name, builtIn: updated[index].builtIn,
                method: updated[index].method, brightness: normalized)
        }
        displays = updated
        changed()
    }

    func shutdown() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        screenObserver = nil
        wakeObserver = nil
        restoreGamma()
        routes.removeAll()
        displays.removeAll()
        changed()
    }

    private func currentBrightness(_ id: UInt32) -> Double {
        displays.first(where: { $0.id == id })?.brightness ?? 1
    }

    private func captureGamma(for id: UInt32) {
        let fingerprint = Self.fingerprint(id)
        if gammaTables[id]?.fingerprint == fingerprint, dimmed.contains(id) { return }
        let capacity = 256
        var red = [CGGammaValue](repeating: 0, count: capacity)
        var green = [CGGammaValue](repeating: 0, count: capacity)
        var blue = [CGGammaValue](repeating: 0, count: capacity)
        var count: UInt32 = 0
        guard
            CGGetDisplayTransferByTable(
                id, UInt32(capacity), &red, &green, &blue, &count) == .success,
            count > 0
        else { return }
        let length = Int(min(count, UInt32(capacity)))
        gammaTables[id] = GammaTable(
            red: Array(red.prefix(length)), green: Array(green.prefix(length)),
            blue: Array(blue.prefix(length)), count: UInt32(length), fingerprint: fingerprint)
    }

    private func applyGamma(_ value: Double, to id: UInt32) -> Bool {
        guard let table = gammaTables[id], table.fingerprint == Self.fingerprint(id) else {
            return false
        }
        let factor = DisplayPowerPolicy.gammaFactor(value)
        let red = table.red.map { $0 * factor }
        let green = table.green.map { $0 * factor }
        let blue = table.blue.map { $0 * factor }
        let applied =
            CGSetDisplayTransferByTable(
                id, table.count, red, green, blue) == .success
        if applied {
            if factor < 0.999 { dimmed.insert(id) } else { dimmed.remove(id) }
        }
        return applied
    }

    private func restoreGamma() {
        for (id, table) in gammaTables where table.fingerprint == Self.fingerprint(id) {
            _ = CGSetDisplayTransferByTable(
                id, table.count, table.red, table.green, table.blue)
        }
        gammaTables.removeAll()
        dimmed.removeAll()
    }

    private func ddcRead(service: CFTypeRef) -> (current: UInt16, maximum: UInt16)? {
        guard let write = DisplayBrightnessBridge.writeI2C,
            let read = DisplayBrightnessBridge.readI2C
        else { return nil }
        var request = DisplayPowerPolicy.ddcReadPacket
        for _ in 0..<3 {
            usleep(10_000)
            guard write(service, 0x37, 0x51, &request, UInt32(request.count)) == KERN_SUCCESS
            else { continue }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 11)
            if read(service, 0x37, 0, &reply, UInt32(reply.count)) == KERN_SUCCESS,
                let parsed = DisplayPowerPolicy.parseDDCReply(reply)
            {
                return parsed
            }
        }
        return nil
    }

    private func ddcWrite(service: CFTypeRef, value: UInt16) -> Bool {
        guard let write = DisplayBrightnessBridge.writeI2C else { return false }
        var packet = DisplayPowerPolicy.ddcWritePacket(value: value)
        var accepted = false
        for _ in 0..<2 {
            usleep(10_000)
            accepted =
                write(service, 0x37, 0x51, &packet, UInt32(packet.count)) == KERN_SUCCESS
                || accepted
        }
        return accepted
    }

    private static func fingerprint(_ id: UInt32) -> String {
        "\(CGDisplayVendorNumber(id)):\(CGDisplayModelNumber(id)):\(CGDisplaySerialNumber(id))"
    }
}

private extension NSScreen {
    var displayPowerID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private enum DisplayBrightnessBridge {
    typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
    typealias CreateWithService =
        @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias WriteI2C =
        @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    typealias ReadI2C =
        @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let displayServices = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let coreDisplay = dlopen(
        "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)

    static let getBrightness: GetBrightness? = symbol(
        displayServices, "DisplayServicesGetBrightness")
    static let setBrightness: SetBrightness? = symbol(
        displayServices, "DisplayServicesSetBrightness")
    static let createWithService: CreateWithService? = symbol(
        coreDisplay, "IOAVServiceCreateWithService")
    static let writeI2C: WriteI2C? = symbol(coreDisplay, "IOAVServiceWriteI2C")
    static let readI2C: ReadI2C? = symbol(coreDisplay, "IOAVServiceReadI2C")

    static func externalServices() -> [CFTypeRef] {
        guard let createWithService else { return [] }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != IO_OBJECT_NULL else { return [] }
        defer { IOObjectRelease(root) }
        var iterator = io_iterator_t()
        guard
            IORegistryEntryCreateIterator(
                root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator)
                == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var services: [CFTypeRef] = []
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(entry) }
            var name = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS,
                String(cString: name) == "DCPAVServiceProxy",
                let location = IORegistryEntryCreateCFProperty(
                    entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                    as? String,
                location == "External",
                let service = createWithService(kCFAllocatorDefault, entry)?.takeRetainedValue()
            else { continue }
            services.append(service)
        }
        return services
    }

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
