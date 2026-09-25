import Foundation

extension UserDefaults {
    public func setIfChanged(_ value: String, forKey key: String) {
        guard string(forKey: key) != value else { return }
        set(value, forKey: key)
    }

    public func setIfChanged(_ value: Int, forKey key: String) {
        guard (object(forKey: key) as? NSNumber)?.intValue != value else { return }
        set(value, forKey: key)
    }

    public func setIfChanged(_ value: Bool, forKey key: String) {
        guard (object(forKey: key) as? NSNumber)?.boolValue != value else { return }
        set(value, forKey: key)
    }
}
