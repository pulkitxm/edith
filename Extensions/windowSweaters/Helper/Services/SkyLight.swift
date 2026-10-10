import CoreGraphics
import Foundation

enum SkyLight {
    typealias Connection = Int32
    typealias WindowID = UInt32
    typealias SpaceID = UInt64
    typealias Opaque = UnsafeMutableRawPointer

    static let notifyProcSignature = "void(uint32_t, void*, size_t, void*)"

    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)

    private static func bind<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    static func release(_ pointer: UnsafeMutableRawPointer?) {
        guard let pointer else { return }
        Unmanaged<AnyObject>.fromOpaque(pointer).release()
    }

    static var isAvailable: Bool {
        mainConnectionID != nil && newWindow != nil && windowContextCreate != nil
            && registerNotifyProc != nil && transactionCreate != nil
            && windowQueryWindows != nil && copyWindowsWithOptionsAndTags != nil
    }

    static let mainConnectionID = bind(
        "SLSMainConnectionID", (@convention(c) () -> Connection).self)
    static let newConnection = bind(
        "SLSNewConnection",
        (@convention(c) (Int32, UnsafeMutablePointer<Connection>) -> CGError).self)
    static let releaseConnection = bind(
        "SLSReleaseConnection", (@convention(c) (Connection) -> CGError).self)

    static let getWindowBounds = bind(
        "SLSGetWindowBounds",
        (@convention(c) (Connection, WindowID, UnsafeMutablePointer<CGRect>) -> CGError).self)
    static let windowIsOrderedIn = bind(
        "SLSWindowIsOrderedIn",
        (@convention(c) (Connection, WindowID, UnsafeMutablePointer<ObjCBool>) -> CGError).self)
    static let newWindow = bind(
        "SLSNewWindow",
        (@convention(c) (
            Connection, Int32, Float, Float, Opaque, UnsafeMutablePointer<WindowID>
        ) -> CGError).self)
    static let releaseWindow = bind(
        "SLSReleaseWindow", (@convention(c) (Connection, WindowID) -> CGError).self)
    static let setWindowTags = bind(
        "SLSSetWindowTags",
        (@convention(c) (Connection, WindowID, UnsafeMutablePointer<UInt64>, Int32) -> CGError)
            .self)
    static let clearWindowTags = bind(
        "SLSClearWindowTags",
        (@convention(c) (Connection, WindowID, UnsafeMutablePointer<UInt64>, Int32) -> CGError)
            .self)
    static let setWindowShape = bind(
        "SLSSetWindowShape",
        (@convention(c) (Connection, WindowID, Float, Float, Opaque) -> CGError).self)
    static let setWindowResolution = bind(
        "SLSSetWindowResolution",
        (@convention(c) (Connection, WindowID, Double) -> CGError).self)
    static let setWindowOpacity = bind(
        "SLSSetWindowOpacity",
        (@convention(c) (Connection, WindowID, ObjCBool) -> CGError).self)
    static let setWindowAlpha = bind(
        "SLSSetWindowAlpha", (@convention(c) (Connection, WindowID, Float) -> CGError).self)
    static let windowSetShadowProperties = bind(
        "SLSWindowSetShadowProperties",
        (@convention(c) (WindowID, CFDictionary) -> CGError).self)
    static let windowContextCreate = bind(
        "SLWindowContextCreate",
        (@convention(c) (Connection, WindowID, CFDictionary?) -> Unmanaged<CGContext>?).self)
    static let flushWindowContentRegion = bind(
        "SLSFlushWindowContentRegion",
        (@convention(c) (Connection, WindowID, Opaque?) -> CGError).self)
    static let windowFreeze = bind(
        "SLSWindowFreezeWithOptions",
        (@convention(c) (Connection, WindowID, Opaque?) -> CGError).self)
    static let windowThaw = bind(
        "SLSWindowThaw", (@convention(c) (Connection, WindowID) -> CGError).self)
    static let disableUpdate = bind(
        "SLSDisableUpdate", (@convention(c) (Connection) -> CGError).self)
    static let reenableUpdate = bind(
        "SLSReenableUpdate", (@convention(c) (Connection) -> CGError).self)

    static let getWindowOwner = bind(
        "SLSGetWindowOwner",
        (@convention(c) (Connection, WindowID, UnsafeMutablePointer<Connection>) -> CGError).self)
    static let connectionGetPID = bind(
        "SLSConnectionGetPID",
        (@convention(c) (Connection, UnsafeMutablePointer<pid_t>) -> CGError).self)
    static let requestNotificationsForWindows = bind(
        "SLSRequestNotificationsForWindows",
        (@convention(c) (Connection, UnsafeMutablePointer<WindowID>, Int32) -> CGError).self)
    static let registerNotifyProc = bind(
        "SLSRegisterNotifyProc",
        (@convention(c) (Opaque, UInt32, Opaque?) -> CGError).self)

    static let newRegionWithRect = bind(
        "CGSNewRegionWithRect",
        (@convention(c) (
            UnsafePointer<CGRect>, UnsafeMutablePointer<UnsafeMutableRawPointer?>
        ) -> CGError).self)

    static let moveWindowsToManagedSpace = bind(
        "SLSMoveWindowsToManagedSpace",
        (@convention(c) (Connection, CFArray, SpaceID) -> CGError).self)
    static let copySpacesForWindows = bind(
        "SLSCopySpacesForWindows",
        (@convention(c) (Connection, Int32, CFArray) -> Unmanaged<CFArray>?).self)
    static let copyManagedDisplays = bind(
        "SLSCopyManagedDisplays", (@convention(c) (Connection) -> Unmanaged<CFArray>?).self)
    static let copyManagedDisplaySpaces = bind(
        "SLSCopyManagedDisplaySpaces", (@convention(c) (Connection) -> Unmanaged<CFArray>?).self)
    static let managedDisplayGetCurrentSpace = bind(
        "SLSManagedDisplayGetCurrentSpace",
        (@convention(c) (Connection, CFString) -> SpaceID).self)
    static let copyManagedDisplayForWindow = bind(
        "SLSCopyManagedDisplayForWindow",
        (@convention(c) (Connection, WindowID) -> Unmanaged<CFString>?).self)
    static let copyActiveMenuBarDisplayIdentifier = bind(
        "SLSCopyActiveMenuBarDisplayIdentifier",
        (@convention(c) (Connection) -> Unmanaged<CFString>?).self)
    static let copyWindowsWithOptionsAndTags = bind(
        "SLSCopyWindowsWithOptionsAndTags",
        (@convention(c) (
            Connection, UInt32, CFArray, UInt32, UnsafeMutablePointer<UInt64>,
            UnsafeMutablePointer<UInt64>
        ) -> Unmanaged<CFArray>?).self)

    static let windowQueryWindows = bind(
        "SLSWindowQueryWindows",
        (@convention(c) (Connection, CFArray, UInt32) -> Unmanaged<AnyObject>?).self)
    static let windowQueryResultCopyWindows = bind(
        "SLSWindowQueryResultCopyWindows",
        (@convention(c) (AnyObject) -> Unmanaged<AnyObject>?).self)
    static let windowIteratorAdvance = bind(
        "SLSWindowIteratorAdvance", (@convention(c) (AnyObject) -> ObjCBool).self)
    static let windowIteratorGetCount = bind(
        "SLSWindowIteratorGetCount", (@convention(c) (AnyObject) -> Int32).self)
    static let windowIteratorGetWindowID = bind(
        "SLSWindowIteratorGetWindowID", (@convention(c) (AnyObject) -> WindowID).self)
    static let windowIteratorGetTags = bind(
        "SLSWindowIteratorGetTags", (@convention(c) (AnyObject) -> UInt64).self)
    static let windowIteratorGetAttributes = bind(
        "SLSWindowIteratorGetAttributes", (@convention(c) (AnyObject) -> UInt64).self)
    static let windowIteratorGetParentID = bind(
        "SLSWindowIteratorGetParentID", (@convention(c) (AnyObject) -> WindowID).self)
    static let windowIteratorGetLevel = bind(
        "SLSWindowIteratorGetLevel", (@convention(c) (AnyObject) -> Int32).self)
    static let windowIteratorGetCornerRadii = bind(
        "SLSWindowIteratorGetCornerRadii", (@convention(c) (AnyObject) -> Unmanaged<CFArray>?).self)
    static let getWindowSubLevel = bind(
        "SLSGetWindowSubLevel", (@convention(c) (Connection, WindowID) -> Int32).self)

    static let getFrontProcess = bind(
        "_SLPSGetFrontProcess",
        (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus).self)
    static let getConnectionIDForPSN = bind(
        "SLSGetConnectionIDForPSN",
        (@convention(c) (
            Connection, UnsafeMutablePointer<ProcessSerialNumber>,
            UnsafeMutablePointer<Connection>
        ) -> CGError).self)

    static let transactionCreate = bind(
        "SLSTransactionCreate", (@convention(c) (Connection) -> Unmanaged<AnyObject>?).self)
    static let transactionSetWindowLevel = bind(
        "SLSTransactionSetWindowLevel",
        (@convention(c) (AnyObject, WindowID, Int32) -> CGError).self)
    static let transactionSetWindowSubLevel = bind(
        "SLSTransactionSetWindowSubLevel",
        (@convention(c) (AnyObject, WindowID, Int32) -> CGError).self)
    static let transactionMoveWindowWithGroup = bind(
        "SLSTransactionMoveWindowWithGroup",
        (@convention(c) (AnyObject, WindowID, CGPoint) -> CGError).self)
    static let transactionOrderWindow = bind(
        "SLSTransactionOrderWindow",
        (@convention(c) (AnyObject, WindowID, Int32, WindowID) -> CGError).self)
    static let transactionSetWindowTransform = bind(
        "SLSTransactionSetWindowTransform",
        (@convention(c) (AnyObject, WindowID, Int32, Int32, CGAffineTransform) -> CGError).self)
    static let transactionCommit = bind(
        "SLSTransactionCommit", (@convention(c) (AnyObject, Int32) -> CGError).self)
}

enum SweaterWindowTag {
    static let document: UInt64 = 1 << 0
    static let floating: UInt64 = 1 << 1
    static let attached: UInt64 = 1 << 7
    static let sticky: UInt64 = 1 << 11
    static let ignoresCycle: UInt64 = 1 << 18
    static let modal: UInt64 = 1 << 31
}

enum SweaterEvent {
    static let windowUpdate: UInt32 = 723
    static let windowClose: UInt32 = 804
    static let windowMove: UInt32 = 806
    static let windowResize: UInt32 = 807
    static let windowReorder: UInt32 = 808
    static let windowLevel: UInt32 = 811
    static let windowUnhide: UInt32 = 815
    static let windowHide: UInt32 = 816
    static let windowTitle: UInt32 = 1322
    static let windowCreate: UInt32 = 1325
    static let windowDestroy: UInt32 = 1326
    static let spaceChange: UInt32 = 1401
    static let frontChange: UInt32 = 1508
}

enum SkyLightSupport {
    static func windowArray(_ windows: [SkyLight.WindowID]) -> CFArray? {
        windows.map { NSNumber(value: Int32(bitPattern: $0)) } as CFArray
    }

    static func spaceArray(_ spaces: [SkyLight.SpaceID]) -> CFArray? {
        spaces.map { NSNumber(value: Int64(bitPattern: $0)) } as CFArray
    }

    static func region(for rect: CGRect) -> UnsafeMutableRawPointer? {
        guard let make = SkyLight.newRegionWithRect else { return nil }
        var frame = rect
        var region: UnsafeMutableRawPointer?
        guard make(&frame, &region) == .success else { return nil }
        return region
    }

    static func withIterator<T>(
        connection: SkyLight.Connection, windows: CFArray, body: (AnyObject) -> T?
    ) -> T? {
        guard
            let query = SkyLight.windowQueryWindows?(connection, windows, 0)?
                .takeRetainedValue(),
            let copy = SkyLight.windowQueryResultCopyWindows,
            let iterator = copy(query)?.takeRetainedValue()
        else { return nil }
        return body(iterator)
    }

    static func isSuitable(_ iterator: AnyObject) -> Bool {
        guard let tagsOf = SkyLight.windowIteratorGetTags,
            let attributesOf = SkyLight.windowIteratorGetAttributes,
            let parentOf = SkyLight.windowIteratorGetParentID
        else { return false }
        let tags = tagsOf(iterator)
        let attributes = attributesOf(iterator)
        guard parentOf(iterator) == 0 else { return false }
        guard (attributes & 0x2) != 0 || (tags & 0x0400_0000_0000_0000) != 0 else { return false }
        guard tags & SweaterWindowTag.attached == 0 else { return false }
        guard tags & SweaterWindowTag.ignoresCycle == 0 else { return false }
        if tags & SweaterWindowTag.document != 0 { return true }
        return tags & SweaterWindowTag.floating != 0 && tags & SweaterWindowTag.modal != 0
    }
}
