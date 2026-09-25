import Foundation

enum LocalStorageSeed {
    static let messageName = "edithLocalStorageSeed"
    static let originLimitBytes = 1_048_576

    static func script(origin: String, items: [String: String]) -> String? {
        guard
            let originJSON = json(origin),
            let itemsData = try? JSONSerialization.data(
                withJSONObject: items, options: [.sortedKeys]),
            itemsData.count <= originLimitBytes,
            let itemsJSON = String(data: itemsData, encoding: .utf8)
        else { return nil }
        return """
            (function () {
            if (window.location.origin !== \(originJSON)) { return; }
            try {
            var store = window.localStorage;
            var items = \(itemsJSON);
            Object.keys(items).forEach(function (key) {
            if (store.getItem(key) === null) { store.setItem(key, items[key]); }
            });
            } catch (error) {}
            try {
            window.webkit.messageHandlers.\(messageName).postMessage(\(originJSON));
            } catch (error) {}
            })();
            """
    }

    static func importable(_ origins: [String: [String: String]]) -> [String: [String: String]] {
        origins.filter { origin, items in
            !items.isEmpty && script(origin: origin, items: items) != nil
        }
    }

    private static func json(_ value: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return String(text.dropFirst().dropLast())
    }
}
