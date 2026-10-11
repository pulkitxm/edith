import ApplicationServices
import Foundation

@MainActor
final class FunctionalOriginalUI {
    struct Step: Decodable {
        let role: String
        let label: String
        let action: String
        let value: Value
        let scope: Scope
        let ownedPath: String?

        struct Scope: Decodable {
            let kind: String
            let label: String
        }

        enum Value: Decodable {
            case boolean(Bool), text(String), null
            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if container.decodeNil() { self = .null }
                else if let boolean = try? container.decode(Bool.self) { self = .boolean(boolean) }
                else { self = .text(try container.decode(String.self)) }
            }
        }
    }

    struct Observation {
        let identifier = UUID().uuidString.lowercased()
        let bytes: Data
        var digest: String { FunctionalBytes.digest(bytes) }
    }

    private let application: AXUIElement
    private let windowTitle: String
    private let requireHeld: () throws -> Void
    private let ownedPaths: [String: FunctionalPinnedPath]
    private var performed = 0

    init(host: FunctionalBirth, windowTitle: String, ownedPaths: [String: FunctionalPinnedPath], requireHeld: @escaping () throws -> Void) throws {
        guard AXIsProcessTrusted(), !windowTitle.isEmpty, windowTitle.utf8.count <= 512,
            ownedPaths.count <= 32
        else { throw FunctionalFailure.unavailable("accessibility admission") }
        try host.requireCurrent()
        self.application = AXUIElementCreateApplication(host.pid)
        self.windowTitle = windowTitle
        self.ownedPaths = ownedPaths
        self.requireHeld = requireHeld
        try requireHeld()
    }

    func perform(_ step: Step, deadline: ContinuousClock.Instant) async throws {
        guard performed < 128, !step.label.isEmpty, step.label.utf8.count <= 512,
            let role = Self.roles[step.role]
        else { throw FunctionalFailure.invalid("original control step") }
        try requireHeld()
        let control = try await wait(deadline: deadline) { try self.uniqueControl(role: role, label: step.label, scope: step.scope) }
        try requireHeld()
        let secure = try attribute(control, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole
        guard step.role != "secureTextField" || secure,
            step.role != "textField" || !secure,
            try attribute(control, kAXEnabledAttribute) as? Bool == true
        else { throw FunctionalFailure.invalid("disabled original control") }
        switch (step.action, step.value) {
        case ("set-checkbox", .boolean(let desired)):
            guard step.role == "checkBox", step.ownedPath == nil,
                let value = try attribute(control, kAXValueAttribute) as? NSNumber,
                value.intValue == 0 || value.intValue == 1,
                value.boolValue != desired
            else { throw FunctionalFailure.invalid("checkbox must perform an actual change") }
            try press(control)
            _ = try await wait(deadline: deadline) {
                let current = try self.attribute(control, kAXValueAttribute) as? NSNumber
                return current?.boolValue == desired ? control : nil
            }
        case ("replace-text", .text(let text)):
            guard ["textField", "secureTextField"].contains(step.role), step.ownedPath == nil,
                text.utf8.count <= 4096, !text.utf8.contains(0)
            else { throw FunctionalFailure.invalid("synthetic text step") }
            try set(control, kAXValueAttribute, text as CFString)
            if step.role != "secureTextField" {
                _ = try await wait(deadline: deadline) {
                    try self.attribute(control, kAXValueAttribute) as? String == text ? control : nil
                }
            }
        case ("choose-owned-path", .null):
            guard step.role == "textField", let name = step.ownedPath,
                let owned = ownedPaths[name], step.scope.kind == "panel"
            else { throw FunctionalFailure.invalid("named synthetic chooser capability") }
            try owned.requireCurrent()
            try set(control, kAXValueAttribute, owned.url.path as CFString)
            try owned.requireCurrent()
        case ("click", .null):
            guard step.ownedPath == nil, ["button", "popUpButton", "menuItem", "row"].contains(step.role)
            else { throw FunctionalFailure.invalid("original click step") }
            try press(control)
        default: throw FunctionalFailure.invalid("original action")
        }
        performed += 1
        try requireHeld()
    }

    func observeRendered(role: String, label: String, scope: Step.Scope) throws -> Observation {
        guard let type = Self.roles[role], ["staticText", "textArea", "row"].contains(role)
        else { throw FunctionalFailure.invalid("rendered output observer") }
        try requireHeld()
        guard let element = try uniqueControl(role: type, label: label, scope: scope)
        else { throw FunctionalFailure.invalid("missing rendered output") }
        let value = try attribute(element, kAXValueAttribute) as? String
        let title = try attribute(element, kAXTitleAttribute) as? String
        guard let output = value ?? title, !output.isEmpty, output.utf8.count <= 65536
        else { throw FunctionalFailure.invalid("rendered output bytes") }
        try requireHeld()
        return Observation(bytes: try FunctionalBytes.canonical(["role": role, "label": label, "output": output]))
    }

    private func uniqueControl(role: String, label: String, scope: Step.Scope) throws -> AXUIElement? {
        guard let scopeRole = Self.scopes[scope.kind], !scope.label.isEmpty
        else { throw FunctionalFailure.invalid("original scope") }
        let roots: [AXUIElement]
        if scope.kind == "menu" || scope.kind == "panel" {
            roots = try descendants(application).filter { try matches($0, role: scopeRole, label: scope.label) }
        } else {
            guard let windows = try attribute(application, kAXWindowsAttribute) as? [AXUIElement]
            else { throw FunctionalFailure.invalid("original windows") }
            let selected = try windows.filter { try matches($0, role: kAXWindowRole, label: windowTitle) }
            guard selected.count == 1 else { return nil }
            roots = scope.kind == "window" ? selected : try descendants(selected[0]).filter { try matches($0, role: scopeRole, label: scope.label) }
        }
        guard roots.count <= 1 else { throw FunctionalFailure.invalid("ambiguous original scope") }
        guard let root = roots.first else { return nil }
        let controls = try ([root] + descendants(root)).filter { try matches($0, role: role, label: label) }
        guard controls.count <= 1 else { throw FunctionalFailure.invalid("ambiguous original control") }
        return controls.first
    }

    private func descendants(_ element: AXUIElement) throws -> [AXUIElement] {
        var pending = [element]
        var output: [AXUIElement] = []
        var visited = Set<CFHashCode>()
        while let current = pending.popLast() {
            guard output.count <= 10000 else { throw FunctionalFailure.invalid("accessibility inventory bound") }
            let identity = CFHash(current)
            guard visited.insert(identity).inserted else { continue }
            let children = try attribute(current, kAXChildrenAttribute) as? [AXUIElement] ?? []
            output.append(contentsOf: children)
            pending.append(contentsOf: children)
        }
        return output
    }

    private func matches(_ element: AXUIElement, role: String, label: String) throws -> Bool {
        guard try attribute(element, kAXRoleAttribute) as? String == role else { return false }
        let title = try attribute(element, kAXTitleAttribute) as? String
        let identifier = try attribute(element, kAXIdentifierAttribute) as? String
        let description = try attribute(element, kAXDescriptionAttribute) as? String
        return title == label || identifier == label || description == label
    }

    private func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if result == .attributeUnsupported || result == .noValue { return nil }
        guard result == .success else { throw FunctionalFailure.invalid("accessibility attribute") }
        return value
    }

    private func set(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) throws {
        guard AXUIElementSetAttributeValue(element, name as CFString, value) == .success
        else { throw FunctionalFailure.invalid("original text control") }
    }

    private func press(_ element: AXUIElement) throws {
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        else { throw FunctionalFailure.invalid("original control press") }
    }

    private func wait(deadline: ContinuousClock.Instant, find: () throws -> AXUIElement?) async throws -> AXUIElement {
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try requireHeld()
            if let result = try find() { return result }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw FunctionalFailure.timeout("original control")
    }

    private static let roles = [
        "checkBox": kAXCheckBoxRole, "button": kAXButtonRole,
        "textField": kAXTextFieldRole, "secureTextField": kAXTextFieldRole,
        "popUpButton": kAXPopUpButtonRole, "menuItem": kAXMenuItemRole,
        "row": kAXRowRole, "staticText": kAXStaticTextRole, "textArea": kAXTextAreaRole,
    ]
    private static let scopes = [
        "window": kAXWindowRole, "sheet": kAXSheetRole, "menu": kAXMenuRole,
        "row": kAXRowRole, "panel": kAXWindowRole,
    ]
}
