import AppKit
import CoreGraphics
import Foundation

enum SweaterWindowServer {
    static var mainConnection: SkyLight.Connection { SkyLight.mainConnectionID?() ?? 0 }

    static func newConnection() -> SkyLight.Connection {
        var connection: SkyLight.Connection = 0
        guard let create = SkyLight.newConnection, create(0, &connection) == .success,
            connection != 0
        else { return mainConnection }
        return connection
    }

    static func releaseConnection(_ connection: SkyLight.Connection) {
        guard connection != 0, connection != mainConnection else { return }
        _ = SkyLight.releaseConnection?(connection)
    }

    static func bounds(of window: SkyLight.WindowID, connection: SkyLight.Connection) -> CGRect? {
        guard let read = SkyLight.getWindowBounds else { return nil }
        var frame = CGRect.zero
        guard read(connection, window, &frame) == .success else { return nil }
        return frame
    }

    static func isOrderedIn(_ window: SkyLight.WindowID, connection: SkyLight.Connection) -> Bool? {
        guard let read = SkyLight.windowIsOrderedIn else { return nil }
        var shown = ObjCBool(false)
        guard read(connection, window, &shown) == .success else { return nil }
        return shown.boolValue
    }

    static func ownerPID(of window: SkyLight.WindowID, connection: SkyLight.Connection) -> pid_t? {
        guard let ownerOf = SkyLight.getWindowOwner, let pidOf = SkyLight.connectionGetPID
        else { return nil }
        var owner: SkyLight.Connection = 0
        guard ownerOf(connection, window, &owner) == .success else { return nil }
        var pid: pid_t = 0
        guard pidOf(owner, &pid) == .success else { return nil }
        return pid
    }

    static func tags(of window: SkyLight.WindowID, connection: SkyLight.Connection) -> UInt64 {
        guard let list = SkyLightSupport.windowArray([window]) else { return 0 }
        return SkyLightSupport.withIterator(connection: connection, windows: list) { iterator in
            guard let count = SkyLight.windowIteratorGetCount, count(iterator) > 0,
                SkyLight.windowIteratorAdvance?(iterator).boolValue == true
            else { return nil }
            return SkyLight.windowIteratorGetTags?(iterator)
        } ?? 0
    }

    static func level(of window: SkyLight.WindowID, connection: SkyLight.Connection) -> Int32 {
        guard let list = SkyLightSupport.windowArray([window]) else { return 0 }
        return SkyLightSupport.withIterator(connection: connection, windows: list) { iterator in
            guard SkyLight.windowIteratorAdvance?(iterator).boolValue == true else { return nil }
            return SkyLight.windowIteratorGetLevel?(iterator)
        } ?? 0
    }

    static func subLevel(of window: SkyLight.WindowID, connection: SkyLight.Connection) -> Int32 {
        SkyLight.getWindowSubLevel?(connection, window) ?? 0
    }

    static func cornerRadius(of iterator: AnyObject) -> Double {
        guard let radiiOf = SkyLight.windowIteratorGetCornerRadii,
            let radii = radiiOf(iterator)?.takeRetainedValue() as? [NSNumber],
            let first = radii.first
        else { return 9 }
        let value = first.doubleValue
        return value > 0 ? value : 9
    }

    static func space(of window: SkyLight.WindowID, connection: SkyLight.Connection)
        -> SkyLight.SpaceID
    {
        if let list = SkyLightSupport.windowArray([window]),
            let spaces = SkyLight.copySpacesForWindows?(connection, 0x7, list)?
                .takeRetainedValue() as? [NSNumber],
            let first = spaces.first
        {
            let identifier = first.uint64Value
            if identifier != 0 { return identifier }
        }
        guard
            let display = SkyLight.copyManagedDisplayForWindow?(connection, window)?
                .takeRetainedValue()
        else { return 0 }
        return SkyLight.managedDisplayGetCurrentSpace?(connection, display) ?? 0
    }

    static func send(
        _ window: SkyLight.WindowID, to space: SkyLight.SpaceID,
        connection: SkyLight.Connection
    ) {
        guard let list = SkyLightSupport.windowArray([window]) else { return }
        _ = SkyLight.moveWindowsToManagedSpace?(connection, list, space)
    }

    static func visibleSpaces(connection: SkyLight.Connection) -> [SkyLight.SpaceID] {
        guard
            let displays = SkyLight.copyManagedDisplays?(connection)?.takeRetainedValue()
                as? [CFString],
            let currentSpace = SkyLight.managedDisplayGetCurrentSpace
        else { return [] }
        return displays.map { currentSpace(connection, $0) }
    }

    static func isSpaceVisible(_ space: SkyLight.SpaceID, connection: SkyLight.Connection) -> Bool {
        visibleSpaces(connection: connection).contains(space)
    }

    static func allSpaces(connection: SkyLight.Connection) -> [SkyLight.SpaceID] {
        guard
            let displays = SkyLight.copyManagedDisplaySpaces?(connection)?.takeRetainedValue()
                as? [[String: Any]]
        else { return [] }
        var spaces: [SkyLight.SpaceID] = []
        for display in displays {
            guard let list = display["Spaces"] as? [[String: Any]] else { continue }
            for space in list {
                guard let identifier = space["id64"] as? NSNumber else { continue }
                spaces.append(identifier.uint64Value)
            }
        }
        return spaces
    }

    static func windows(
        onSpaces spaces: [SkyLight.SpaceID], owner: UInt32 = 0,
        connection: SkyLight.Connection
    ) -> CFArray? {
        guard let list = SkyLightSupport.spaceArray(spaces),
            let copy = SkyLight.copyWindowsWithOptionsAndTags
        else { return nil }
        var setTags: UInt64 = 1
        var clearTags: UInt64 = 0
        return copy(connection, owner, list, 0x2, &setTags, &clearTags)?.takeRetainedValue()
    }

    static func frontWindow(connection: SkyLight.Connection) -> SkyLight.WindowID {
        guard let frontProcess = SkyLight.getFrontProcess,
            let connectionForPSN = SkyLight.getConnectionIDForPSN
        else { return 0 }
        var psn = ProcessSerialNumber()
        guard frontProcess(&psn) == noErr else { return 0 }
        var target: SkyLight.Connection = 0
        guard connectionForPSN(connection, &psn, &target) == .success else { return 0 }

        let active = activeSpace(connection: connection)
        guard active != 0,
            let list = windows(
                onSpaces: [active], owner: UInt32(bitPattern: target),
                connection: connection),
            CFArrayGetCount(list) > 0
        else { return 0 }

        return SkyLightSupport.withIterator(connection: connection, windows: list) { iterator in
            guard let advance = SkyLight.windowIteratorAdvance,
                let windowOf = SkyLight.windowIteratorGetWindowID
            else { return nil }
            while advance(iterator).boolValue {
                if SkyLightSupport.isSuitable(iterator) { return windowOf(iterator) }
            }
            return nil
        } ?? 0
    }

    static func activeSpace(connection: SkyLight.Connection) -> SkyLight.SpaceID {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        if count == 1 {
            var display: CGDirectDisplayID = 0
            var found: UInt32 = 0
            CGGetActiveDisplayList(1, &display, &found)
            guard found == 1,
                let uuid = CGDisplayCreateUUIDFromDisplayID(display)?
                    .takeRetainedValue(), let string = CFUUIDCreateString(nil, uuid)
            else { return 0 }
            return SkyLight.managedDisplayGetCurrentSpace?(connection, string) ?? 0
        }
        guard
            let identifier = SkyLight.copyActiveMenuBarDisplayIdentifier?(connection)?
                .takeRetainedValue()
        else { return 0 }
        return SkyLight.managedDisplayGetCurrentSpace?(connection, identifier) ?? 0
    }

    static func createOverlay(frame: CGRect, hidpi: Bool, connection: SkyLight.Connection)
        -> SkyLight.WindowID
    {
        guard let region = SkyLightSupport.region(for: frame), let create = SkyLight.newWindow
        else { return 0 }
        defer { SkyLight.release(region) }

        var window: SkyLight.WindowID = 0
        guard create(connection, 2, -9999, -9999, region, &window) == .success, window != 0
        else { return 0 }

        _ = SkyLight.setWindowResolution?(connection, window, hidpi ? 2 : 1)
        var setTags: UInt64 = SweaterWindowTag.floating | (1 << 9)
        var clearTags: UInt64 = 0
        _ = SkyLight.setWindowTags?(connection, window, &setTags, 64)
        _ = SkyLight.clearWindowTags?(connection, window, &clearTags, 64)
        _ = SkyLight.setWindowOpacity?(connection, window, ObjCBool(false))

        let shadow = [kSweaterShadowDensityKey: 0] as CFDictionary
        _ = SkyLight.windowSetShadowProperties?(window, shadow)
        return window
    }

    static func withTransaction(
        connection: SkyLight.Connection, _ body: (AnyObject) -> Void
    ) -> Bool {
        guard let transaction = SkyLight.transactionCreate?(connection)?.takeRetainedValue(),
            let commit = SkyLight.transactionCommit
        else { return false }
        body(transaction)
        _ = commit(transaction, 0)
        return true
    }
}

let kSweaterShadowDensityKey = "com.apple.WindowShadowDensity"
