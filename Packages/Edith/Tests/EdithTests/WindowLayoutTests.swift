import Foundation
import Testing

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
}
