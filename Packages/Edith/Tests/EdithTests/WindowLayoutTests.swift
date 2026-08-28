import Foundation
import Testing

@testable import EdithCLI
@testable import EdithHelper
@testable import EdithKit

@Suite struct WindowLayoutTests {
    private let screen = CGRect(x: 0, y: 25, width: 1440, height: 875)
    private let window = CGRect(x: 210, y: 180, width: 900, height: 600)

    @Test func primaryLayoutsUseTheVisibleScreen() {
        #expect(
            WindowLayoutGeometry.frame(for: .leftHalf, current: window, visibleFrame: screen)
                == CGRect(x: 0, y: 25, width: 720, height: 875))
        #expect(
            WindowLayoutGeometry.frame(for: .rightHalf, current: window, visibleFrame: screen)
                == CGRect(x: 720, y: 25, width: 720, height: 875))
        #expect(
            WindowLayoutGeometry.frame(for: .topLeft, current: window, visibleFrame: screen)
                == CGRect(x: 0, y: 463, width: 720, height: 437))
        #expect(
            WindowLayoutGeometry.frame(for: .maximize, current: window, visibleFrame: screen)
                == screen)
    }

    @Test func centerKeepsTheCurrentSizeWithinTheScreen() {
        #expect(
            WindowLayoutGeometry.frame(for: .center, current: window, visibleFrame: screen)
                == CGRect(x: 270, y: 163, width: 900, height: 600))
        let oversized = CGRect(x: -20, y: -10, width: 1800, height: 1000)
        #expect(
            WindowLayoutGeometry.frame(for: .center, current: oversized, visibleFrame: screen)
                == screen)
    }

    @Test func movingDisplaysPreservesRelativePositionAndClampsSize() {
        let source = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let destination = CGRect(x: 1440, y: 0, width: 1024, height: 768)
        let moved = WindowLayoutGeometry.movedFrame(
            current: CGRect(x: 270, y: 163, width: 900, height: 600), from: source,
            to: destination)

        #expect(moved == CGRect(x: 1502, y: 84, width: 900, height: 600))
    }

    @Test func everyPlacementCoversItsExpectedScreenRegion() {
        let expected: [WindowLayoutAction: CGRect] = [
            .leftHalf: CGRect(x: 0, y: 25, width: 720, height: 875),
            .rightHalf: CGRect(x: 720, y: 25, width: 720, height: 875),
            .topHalf: CGRect(x: 0, y: 463, width: 1440, height: 437),
            .bottomHalf: CGRect(x: 0, y: 25, width: 1440, height: 438),
            .topLeft: CGRect(x: 0, y: 463, width: 720, height: 437),
            .topRight: CGRect(x: 720, y: 463, width: 720, height: 437),
            .bottomLeft: CGRect(x: 0, y: 25, width: 720, height: 438),
            .bottomRight: CGRect(x: 720, y: 25, width: 720, height: 438),
            .center: CGRect(x: 270, y: 163, width: 900, height: 600),
            .maximize: screen,
        ]

        for (action, frame) in expected {
            #expect(
                WindowLayoutGeometry.frame(for: action, current: window, visibleFrame: screen)
                    == frame)
        }
        #expect(
            WindowLayoutGeometry.frame(for: .nextDisplay, current: window, visibleFrame: screen)
                == nil)
        #expect(
            WindowLayoutGeometry.frame(for: .restore, current: window, visibleFrame: screen) == nil)
    }

    @Test func coordinateConversionUsesTheMenuBarDisplayInsteadOfTheDesktopTop() {
        let appKit = CGRect(x: -900, y: 1000, width: 800, height: 600)
        let accessibility = WindowCoordinateGeometry.accessibilityFrame(
            fromAppKit: appKit, menuBarScreenTopY: 900)

        #expect(accessibility == CGRect(x: -900, y: -700, width: 800, height: 600))
        #expect(
            WindowCoordinateGeometry.appKitFrame(
                fromAccessibility: accessibility, menuBarScreenTopY: 900) == appKit)
    }

    @Test func restoreHistoryIsBoundedAndIndependentPerWindow() {
        var history = WindowFrameHistory<String>(maximumWindows: 2, maximumFramesPerWindow: 2)
        history.record(CGRect(x: 1, y: 0, width: 100, height: 100), for: "first")
        history.record(CGRect(x: 2, y: 0, width: 100, height: 100), for: "first")
        history.record(CGRect(x: 3, y: 0, width: 100, height: 100), for: "first")
        history.record(CGRect(x: 4, y: 0, width: 100, height: 100), for: "second")

        #expect(history.windowCount == 2)
        #expect(history.pop(for: "first")?.minX == 3)
        #expect(history.pop(for: "first")?.minX == 2)
        #expect(history.pop(for: "first") == nil)

        history.record(CGRect(x: 5, y: 0, width: 100, height: 100), for: "third")
        history.record(CGRect(x: 6, y: 0, width: 100, height: 100), for: "fourth")
        #expect(history.windowCount == 2)
        #expect(history.pop(for: "second") == nil)
        #expect(history.pop(for: "third")?.minX == 5)
        #expect(history.pop(for: "fourth")?.minX == 6)
    }

    @Test func operationsHaveUniqueCLIPaths() {
        let descriptors = WindowLayoutAction.allCases.map(\.descriptor)
        #expect(Set(descriptors.map(\.id)).count == descriptors.count)
        #expect(Set(descriptors.map(\.cli)).count == descriptors.count)
    }

    @Test func requestCarriesTheSelectedAction() {
        var name: Notification.Name?
        var payload: [String: Any]?
        let descriptor = WindowLayoutRequest.send(.topRight) {
            name = $0
            payload = $1
        }

        #expect(name == IPC.Name.requestWindowLayout)
        #expect(payload?[WindowLayoutRequest.actionKey] as? String == "top-right")
        #expect(descriptor == WindowLayoutAction.topRight.descriptor)
    }

    @Test func cliDispatchesOneTypedJSONRequest() async {
        await CLIProbe.inWorld { world in
            world.shared.set(true, forKey: AppStorageKeys.WindowTools.enabled)
            world.helperRunning(true)
            let result = await CLIProbe.capture(["window", "top-right", "--json"])

            #expect(result.code == 0)
            #expect(result.object?["action"] as? String == "top-right")
            #expect(result.object?["operation"] as? String == "window.top-right")
            #expect(
                world.postedPayloads(for: IPC.Name.requestWindowLayout).first?[
                    WindowLayoutRequest.actionKey] as? String == "top-right")
        }
    }

    @Test func cliStatusIsTheSafeDefault() async {
        await CLIProbe.inWorld { world in
            world.shared.set(true, forKey: AppStorageKeys.WindowTools.enabled)
            world.shared.set(
                true, forKey: AppStorageKeys.Permissions.accessibilityGranted)
            world.helperRunning(true)
            let explicit = await CLIProbe.capture(["window", "status", "--json"])
            let implicit = await CLIProbe.capture(["window", "--json"])

            #expect(explicit.code == 0)
            #expect(explicit.stdout == implicit.stdout)
            #expect(explicit.object?["enabled"] as? Bool == true)
            #expect(explicit.object?["helperRunning"] as? Bool == true)
            #expect(explicit.object?["accessibilityGranted"] as? Bool == true)
            #expect(explicit.object?["available"] as? Bool == true)
            #expect(
                explicit.object?["actions"] as? [String]
                    == WindowLayoutAction.allCases.map(\.rawValue))
            #expect(world.postedNames().isEmpty)
        }
    }

    @Test func cliStatusExplainsUnavailableRuntimeWithoutFailing() async {
        await CLIProbe.inWorld { world in
            world.shared.set(true, forKey: AppStorageKeys.WindowTools.enabled)
            world.helperRunning(false)
            let result = await CLIProbe.capture(["window", "status", "--json"])

            #expect(result.code == 0)
            #expect(result.object?["enabled"] as? Bool == true)
            #expect(result.object?["helperRunning"] as? Bool == false)
            #expect(result.object?["accessibilityGranted"] as? Bool == false)
            #expect(result.object?["available"] as? Bool == false)
        }
    }
}
