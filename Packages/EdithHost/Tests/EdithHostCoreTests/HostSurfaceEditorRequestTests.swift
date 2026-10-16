import EdithExtensionSupport
import Foundation
import XCTest

@testable import EdithHostCore

final class HostSurfaceEditorRequestTests: XCTestCase {
    func testInspectHomeAfterNotchSelectsHomeTileAndPreservesLayouts() throws {
        try withPreferences { defaults in
            defaults.set("home-layout", forKey: SurfaceTarget.home.key)
            defaults.set("notch-layout", forKey: SurfaceTarget.notch.key)
            HostSurfaceEditorRequest(target: .notch, tileID: "notch-tile").save(to: defaults)
            HostSurfaceEditorRequest(target: .home, tileID: "home-tile").save(to: defaults)
            XCTAssertEqual(defaults.string(forKey: HostSurfaceEditorKeys.target), "home")
            XCTAssertEqual(defaults.string(forKey: HostSurfaceEditorKeys.widget), "home-tile")
            XCTAssertEqual(defaults.string(forKey: SurfaceTarget.home.key), "home-layout")
            XCTAssertEqual(defaults.string(forKey: SurfaceTarget.notch.key), "notch-layout")
        }
    }

    func testHomeWidgetEditorClearsPreviousTile() throws {
        try withPreferences { defaults in
            HostSurfaceEditorRequest(target: .notch, tileID: "previous-tile").save(to: defaults)
            HostSurfaceEditorRequest(target: .home).save(to: defaults)
            XCTAssertEqual(defaults.string(forKey: HostSurfaceEditorKeys.target), "home")
            XCTAssertEqual(defaults.string(forKey: HostSurfaceEditorKeys.widget), "")
        }
    }

    func testNotchRequestKeepsItsTargetAndUnrelatedPreferences() throws {
        try withPreferences { defaults in
            defaults.set("saved-value", forKey: "unrelatedPreference")
            HostSurfaceEditorRequest(target: .home, tileID: "home-tile").save(to: defaults)
            let token = UUID()
            let request = HostSurfaceEditorRequest(
                token: token, target: .notch, tileID: "notch-tile")
            request.save(to: defaults)
            XCTAssertEqual(request.token, token)
            XCTAssertEqual(defaults.string(forKey: HostSurfaceEditorKeys.target), "notch")
            XCTAssertEqual(defaults.string(forKey: HostSurfaceEditorKeys.widget), "notch-tile")
            XCTAssertEqual(defaults.string(forKey: "unrelatedPreference"), "saved-value")
        }
    }

    private func withPreferences(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "test.surface-editor." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
