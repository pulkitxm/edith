import EdithKit
import SwiftUI

protocol ConfigurationBindingValue {
    var configurationValue: JSONValue { get }
}

extension Bool: ConfigurationBindingValue {
    var configurationValue: JSONValue { .bool(self) }
}

extension Int: ConfigurationBindingValue {
    var configurationValue: JSONValue { .int(self) }
}

extension Double: ConfigurationBindingValue {
    var configurationValue: JSONValue { .double(self) }
}

extension String: ConfigurationBindingValue {
    var configurationValue: JSONValue { .string(self) }
}

extension ColorCopyFormat: ConfigurationBindingValue {
    var configurationValue: JSONValue { .string(rawValue) }
}

extension ColorProfile: ConfigurationBindingValue {
    var configurationValue: JSONValue { .string(rawValue) }
}

extension FocusDimDisplayMode: ConfigurationBindingValue {
    var configurationValue: JSONValue { .string(rawValue) }
}

extension Binding where Value: ConfigurationBindingValue {
    func configured(
        _ key: String, executor: ConfigurationExecutor = .application
    ) -> Binding<Value> {
        Binding(
            get: { wrappedValue },
            set: { value in
                guard (try? executor.set(value.configurationValue, forKey: key)) != nil else {
                    return
                }
                wrappedValue = value
            })
    }
}
