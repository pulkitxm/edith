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

    private struct ExternalDisplay {
        let id: UInt32
        let name: String
        let identity: DisplayPowerDisplayIdentity
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
        var external: [ExternalDisplay] = []

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
                external.append(
                    ExternalDisplay(
                        id: id, name: screen.localizedName,
                        identity: Self.displayIdentity(
                            id, info: DisplayBrightnessBridge.displayInfo(id))))
            }
        }

        let services = DisplayBrightnessBridge.externalServices()
        var scores: [(displayIndex: Int, serviceOrdinal: Int, score: Int)] = []
        for (index, display) in external.enumerated() {
            for service in services {
                scores.append(
                    (
                        index, service.identity.ordinal,
                        DisplayPowerPolicy.matchScore(
                            service: service.identity, display: display.identity)
                    ))
            }
        }
        var assignment = DisplayPowerPolicy.assignServices(scores: scores)
        var unassignedDisplays: [Int] = []
        for index in external.indices where assignment[index] == nil {
            unassignedDisplays.append(index)
        }
        let assignedServices = Set(assignment.values)
        let unassignedServices = services.filter { !assignedServices.contains($0.identity.ordinal) }
        if unassignedDisplays.count == 1, unassignedServices.count == 1 {
            assignment[unassignedDisplays[0]] = unassignedServices[0].identity.ordinal
        }

        for (index, display) in external.enumerated() {
            if let ordinal = assignment[index],
                let matched = services.first(where: { $0.identity.ordinal == ordinal })
            {
                let stored = levels[display.id]
                switch ddcProbe(service: matched.service) {
                case .replied(let current, let reportedMaximum):
                    let maximum = reportedMaximum > 0 ? reportedMaximum : 100
                    let value = stored ?? Double(current) / Double(maximum)
                    nextDisplays.append(
                        DisplayPowerDisplay(
                            id: display.id, name: display.name, builtIn: false, method: .ddc,
                            brightness: value))
                    nextRoutes[display.id] = Route(
                        method: .ddc, service: matched.service, maximum: maximum)
                    continue
                case .writeOnly:
                    let value = stored ?? currentBrightness(display.id, fallback: 0.5)
                    nextDisplays.append(
                        DisplayPowerDisplay(
                            id: display.id, name: display.name, builtIn: false, method: .ddc,
                            brightness: value))
                    nextRoutes[display.id] = Route(
                        method: .ddc, service: matched.service, maximum: 100)
                    continue
                case .dead:
                    break
                }
            }

            captureGamma(for: display.id)
            let value = levels[display.id] ?? currentBrightness(display.id, fallback: 1)
            nextDisplays.append(
                DisplayPowerDisplay(
                    id: display.id, name: display.name, builtIn: false,
                    method: gammaTables[display.id] == nil ? .unavailable : .software,
                    brightness: value))
            if gammaTables[display.id] != nil {
                nextRoutes[display.id] = Route(method: .software, service: nil, maximum: 100)
            }
        }

        restoreUnusedGamma(nextRoutes: nextRoutes)
        routes = nextRoutes
        var orderedDisplays = Array(nextDisplays.prefix(16))
        orderedDisplays.sort { left, right in
            if left.builtIn != right.builtIn { return left.builtIn }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        displays = orderedDisplays
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

    private func currentBrightness(_ id: UInt32, fallback: Double) -> Double {
        displays.first(where: { $0.id == id })?.brightness ?? fallback
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
        var red = table.red
        var green = table.green
        var blue = table.blue
        for index in red.indices { red[index] *= factor }
        for index in green.indices { green[index] *= factor }
        for index in blue.indices { blue[index] *= factor }
        let applied =
            CGSetDisplayTransferByTable(
                id, table.count, red, green, blue) == .success
        if applied {
            if factor < 0.999 { dimmed.insert(id) } else { dimmed.remove(id) }
        }
        return applied
    }

    private func restoreUnusedGamma(nextRoutes: [UInt32: Route]) {
        let unused = gammaTables.filter {
            nextRoutes[$0.key]?.method != .software
                && $0.value.fingerprint == Self.fingerprint($0.key)
        }
        for (id, table) in unused {
            _ = CGSetDisplayTransferByTable(
                id, table.count, table.red, table.green, table.blue)
            gammaTables.removeValue(forKey: id)
            dimmed.remove(id)
        }
    }

    private func restoreGamma() {
        for (id, table) in gammaTables where table.fingerprint == Self.fingerprint(id) {
            _ = CGSetDisplayTransferByTable(
                id, table.count, table.red, table.green, table.blue)
        }
        gammaTables.removeAll()
        dimmed.removeAll()
    }

    private func ddcProbe(service: CFTypeRef) -> DisplayPowerDDCProbeOutcome {
        guard let write = DisplayBrightnessBridge.writeI2C,
            let read = DisplayBrightnessBridge.readI2C
        else { return .dead }
        var request = DisplayPowerPolicy.ddcReadPacket
        var writeAccepted = false
        for _ in 0..<3 {
            usleep(10_000)
            if write(service, 0x37, 0x51, &request, UInt32(request.count)) == KERN_SUCCESS {
                writeAccepted = true
            }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 11)
            if read(service, 0x37, 0, &reply, UInt32(reply.count)) == KERN_SUCCESS,
                let parsed = DisplayPowerPolicy.parseDDCReply(reply)
            {
                return .replied(current: parsed.current, maximum: parsed.maximum)
            }
        }
        return DisplayPowerPolicy.ddcProbeOutcome(writeAccepted: writeAccepted, reply: nil)
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

    private static func displayIdentity(
        _ id: UInt32, info: NSDictionary?
    ) -> DisplayPowerDisplayIdentity {
        guard let info else {
            return DisplayPowerDisplayIdentity(
                vendorID: Int64(CGDisplayVendorNumber(id)),
                productID: Int64(CGDisplayModelNumber(id)),
                serialNumber: Int64(CGDisplaySerialNumber(id)))
        }
        let names = info["DisplayProductName"] as? [String: String]
        return DisplayPowerDisplayIdentity(
            vendorID: (info[kDisplayVendorID] as? NSNumber)?.int64Value,
            productID: (info[kDisplayProductID] as? NSNumber)?.int64Value,
            weekOfManufacture: (info[kDisplayWeekOfManufacture] as? NSNumber)?.int64Value,
            yearOfManufacture: (info[kDisplayYearOfManufacture] as? NSNumber)?.int64Value,
            horizontalImageSize: (info[kDisplayHorizontalImageSize] as? NSNumber)?.int64Value,
            verticalImageSize: (info[kDisplayVerticalImageSize] as? NSNumber)?.int64Value,
            ioDisplayLocation: info[kIODisplayLocationKey] as? String,
            productName: names?["en_US"] ?? names?.first?.value,
            serialNumber: (info[kDisplaySerialNumber] as? NSNumber)?.int64Value)
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
    typealias CreateInfoDictionary =
        @convention(c) (UInt32) -> Unmanaged<CFDictionary>?
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
    static let createInfoDictionary: CreateInfoDictionary? = symbol(
        coreDisplay, "CoreDisplay_DisplayCreateInfoDictionary")
    static let writeI2C: WriteI2C? = symbol(coreDisplay, "IOAVServiceWriteI2C")
    static let readI2C: ReadI2C? = symbol(coreDisplay, "IOAVServiceReadI2C")

    struct ExternalService {
        let identity: DisplayPowerServiceIdentity
        let service: CFTypeRef
    }

    static func displayInfo(_ id: UInt32) -> NSDictionary? {
        createInfoDictionary?(id)?.takeRetainedValue() as NSDictionary?
    }

    static func externalServices() -> [ExternalService] {
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
        var services: [ExternalService] = []
        var pending = DisplayPowerServiceIdentity()
        var ordinal = 0
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(entry) }
            var name = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS else { continue }
            let entryName = String(cString: name)
            if entryName.contains("AppleCLCD2")
                || entryName.contains("IOMobileFramebufferShim")
            {
                ordinal += 1
                pending = DisplayPowerServiceIdentity(ordinal: ordinal)
                pending.edidUUID = property(entry, "EDID UUID") as? String ?? ""
                var path = [CChar](repeating: 0, count: 512)
                if IORegistryEntryGetPath(entry, kIOServicePlane, &path) == KERN_SUCCESS {
                    pending.ioDisplayLocation = String(cString: path)
                }
                if let attributes = property(entry, "DisplayAttributes") as? NSDictionary,
                    let product = attributes["ProductAttributes"] as? NSDictionary
                {
                    pending.productName = product["ProductName"] as? String ?? ""
                    pending.serialNumber =
                        (product["SerialNumber"] as? NSNumber)?.int64Value ?? 0
                }
            } else if entryName == "DCPAVServiceProxy",
                property(entry, "Location") as? String == "External",
                let service = createWithService(kCFAllocatorDefault, entry)?.takeRetainedValue()
            {
                services.append(ExternalService(identity: pending, service: service))
            }
        }
        return services
    }

    private static func property(_ entry: io_service_t, _ key: String) -> AnyObject? {
        IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively))?.takeRetainedValue()
    }

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
