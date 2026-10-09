import Foundation
import Testing

@testable import EdithKit

struct SurfaceWidgetCatalogTests {
    @Test func everyRegisteredExtensionHasAWidget() {
        let widgets = SurfaceWidget.allCases
        let represented = Set(widgets.compactMap { $0.registryEntry?.id })
        #expect(Set(ExtensionRegistry.entries.map(\.id)).isSubset(of: represented))
        #expect(Set(widgets.map(\.rawValue)).count == widgets.count)
        for widget in widgets {
            #expect(!widget.title.isEmpty && !widget.icon.isEmpty && !widget.summary.isEmpty)
            #expect(SurfaceWidget(rawValue: widget.rawValue) == widget)
        }
        #expect(SurfaceWidget(rawValue: "extension:unregistered") == nil)
        #expect(SurfaceWidget(rawValue: "extension:../../file") == nil)
    }

    @Test func extensionWidgetsPersistAsValidatedStringIdentifiers() throws {
        let layout = SurfaceLayout(tiles: SurfaceWidget.allCases.map { SurfaceTile($0) })
            .normalized()
        #expect(SurfaceLayout.decode(layout.encoded, target: .home) == layout)
        let data = try JSONEncoder().encode(SurfaceWidget.ability("downloads"))
        #expect(String(decoding: data, as: UTF8.self) == "\"extension:downloads\"")
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SurfaceWidget.self, from: Data("\"extension:unknown\"".utf8))
        }
    }

    @Test func disabledDependenciesPreventCardsFromUsingAnExtension() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let widget = SurfaceWidget.ability("audioMixer")
        #expect(!widget.available(in: defaults))
        defaults.set(true, forKey: "notchAudioMixerEnabled")
        #expect(!widget.available(in: defaults))
        defaults.set(true, forKey: "notchShelfEnabled")
        #expect(widget.available(in: defaults))
        #expect(SurfaceWidget.github.available(in: defaults))
    }
}
