import ApplicationServices
import Darwin
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
            let anchor: Anchor?
            struct Anchor: Decodable {
                let role: String
                let label: String
            }
        }

        enum Value: Decodable {
            case boolean(Bool), number(Double), text(String), null
            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if container.decodeNil() { self = .null }
                else if let boolean = try? container.decode(Bool.self) { self = .boolean(boolean) }
                else if let number = try? container.decode(Double.self) { self = .number(number) }
                else { self = .text(try container.decode(String.self)) }
            }
        }
    }

    struct ChooserPath {
        let url: URL
        private let existing: FunctionalPinnedPath?
        private let parent: FunctionalPinnedPath

        init(path: String, kind: String, root: String, owner: String) throws {
            url = URL(fileURLWithPath: path)
            guard path == url.standardizedFileURL.path, path == url.resolvingSymlinksInPath().path,
                path.hasPrefix(root + "/"), ["file", "directory"].contains(kind)
            else { throw FunctionalFailure.invalid("signed chooser path") }
            parent = try FunctionalPinnedPath(url.deletingLastPathComponent(), directory: true)
            var state = stat()
            if lstat(path, &state) == 0 {
                existing = try FunctionalPinnedPath(url, directory: kind == "directory")
            } else {
                guard errno == ENOENT, kind == "file", path.hasPrefix(root + "/outputs/" + owner + "/")
                else { throw FunctionalFailure.invalid("signed absent output chooser") }
                existing = nil
            }
        }

        func requireCurrent() throws {
            try parent.requireCurrent()
            if let existing { try existing.requireCurrent() }
            else {
                var state = stat()
                guard lstat(url.path, &state) != 0, errno == ENOENT else {
                    throw FunctionalFailure.invalid("output must remain absent before native Save") }
            }
        }
    }

    struct Observation {
        let identifier = UUID().uuidString.lowercased()
        let bytes: Data
        var digest: String { FunctionalBytes.digest(bytes) }
    }

    private let host: FunctionalBirth
    private let application: AXUIElement
    private let windowTitle: String
    private let requireHeld: () throws -> Void
    private let ownedPaths: [String: ChooserPath]
    private var performed = 0

    init(host: FunctionalBirth, windowTitle: String, ownedPaths: [String: ChooserPath], requireHeld: @escaping () throws -> Void) throws {
        guard AXIsProcessTrusted(), !windowTitle.isEmpty, windowTitle.utf8.count <= 512,
            ownedPaths.count <= 32
        else { throw FunctionalFailure.unavailable("accessibility admission") }
        try host.requireCurrent()
        self.host = host
        self.application = AXUIElementCreateApplication(host.pid)
        self.windowTitle = windowTitle
        self.ownedPaths = ownedPaths
        self.requireHeld = requireHeld
        try requireHeld()
    }

    func perform(_ step: Step, deadline: ContinuousClock.Instant) async throws {
        guard performed < 128, (!step.label.isEmpty || step.scope.kind == "button" && step.scope.anchor != nil), step.label.utf8.count <= 512,
            let role = Self.roles[step.role]
        else { throw FunctionalFailure.invalid("original control step") }
        try requireHeld()
        let control = try await wait(deadline: deadline) { try self.uniqueControl(role: role, label: step.label, scope: step.scope) }
        try requireHeld()
        let secure = try attribute(control, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole
        guard step.role != "secureTextField" || secure,
            step.role != "textField" || !secure,
            try step.action == "choose-owned-path" || attribute(control, kAXEnabledAttribute) as? Bool == true
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
            guard step.role == "button", let name = step.ownedPath,
                let owned = ownedPaths[name], step.scope.kind == "panel",
                ["Save", "Choose", "Open"].contains(step.label)
            else { throw FunctionalFailure.invalid("named synthetic chooser capability") }
            try owned.requireCurrent()
            try await choose(owned, confirmation: step, deadline: deadline)
        case ("set-slider", .number(let target)):
            guard step.role == "slider", target.isFinite, target >= 0, target <= 1,
                let minimum = try attribute(control, kAXMinValueAttribute) as? NSNumber,
                let maximum = try attribute(control, kAXMaxValueAttribute) as? NSNumber,
                minimum.doubleValue < maximum.doubleValue
            else { throw FunctionalFailure.invalid("original slider range") }
            let desired = minimum.doubleValue + target * (maximum.doubleValue - minimum.doubleValue)
            let previous = try attribute(control, kAXValueAttribute) as? NSNumber
            guard previous?.doubleValue != desired else { throw FunctionalFailure.invalid("slider must change") }
            try set(control, kAXValueAttribute, NSNumber(value: desired))
            _ = try await wait(deadline: deadline) {
                guard let value = try self.attribute(control, kAXValueAttribute) as? NSNumber else { return nil }
                return abs(value.doubleValue - desired) <= 0.000001 ? control : nil
            }
        case ("increment", .null), ("decrement", .null):
            guard step.role == "stepper", step.ownedPath == nil else { throw FunctionalFailure.invalid("original stepper") }
            let action = step.action == "increment" ? kAXIncrementAction : kAXDecrementAction
            guard AXUIElementPerformAction(control, action as CFString) == .success
            else { throw FunctionalFailure.invalid("original stepper action") }
        case ("submit", .null):
            guard step.role == "textField", step.ownedPath == nil,
                AXUIElementPerformAction(control, kAXConfirmAction as CFString) == .success
            else { throw FunctionalFailure.invalid("original text submission") }
        case ("click", .null):
            guard step.ownedPath == nil, ["button", "popUpButton", "menuItem", "row", "column"].contains(step.role)
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

    private func choose(_ owned: ChooserPath, confirmation: Step, deadline: ContinuousClock.Instant) async throws {
        try requireHeld()
        try host.requireCurrent()
        guard let current = try uniqueControl(role: kAXButtonRole, label: confirmation.label, scope: confirmation.scope) else {
            throw FunctionalFailure.invalid("original native chooser confirmation") }
        try set(application, kAXFrontmostAttribute, kCFBooleanTrue)
        try key(5, flags: [.maskCommand, .maskShift])
        let field = try await wait(deadline: deadline) {
            guard let focused = try self.attribute(self.application, kAXFocusedUIElementAttribute),
                CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
            let field = unsafeDowncast(focused, to: AXUIElement.self)
            guard try self.attribute(field, kAXRoleAttribute) as? String == kAXTextFieldRole,
                try self.attribute(field, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole
            else { return nil }
            return field
        }
        try requireHeld()
        try owned.requireCurrent()
        try set(field, kAXValueAttribute, owned.url.path as CFString)
        guard try attribute(field, kAXValueAttribute) as? String == owned.url.path else {
            throw FunctionalFailure.invalid("native Go to Folder path") }
        try key(36, flags: [])
        let button = try await wait(deadline: deadline) {
            guard let button = try self.uniqueControl(role: kAXButtonRole, label: confirmation.label, scope: confirmation.scope),
                try self.attribute(button, kAXEnabledAttribute) as? Bool == true
            else { return nil }
            return button
        }
        guard CFEqual(button, current) else { throw FunctionalFailure.invalid("native chooser control changed") }
        try owned.requireCurrent()
        try requireHeld()
        try press(button)
    }

    private func key(_ code: CGKeyCode, flags: CGEventFlags) throws {
        try requireHeld()
        try host.requireCurrent()
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        else { throw FunctionalFailure.invalid("native chooser key event") }
        down.flags = flags
        up.flags = flags
        down.postToPid(host.pid)
        up.postToPid(host.pid)
        try host.requireCurrent()
    }

    private func uniqueControl(role: String, label: String, scope: Step.Scope) throws -> AXUIElement? {
        guard let scopeRole = Self.scopes[scope.kind], !scope.label.isEmpty || scope.anchor != nil
        else { throw FunctionalFailure.invalid("original scope") }
        let roots: [AXUIElement]
        if scope.kind == "menu" || scope.kind == "panel" {
            roots = try descendants(application).filter { try scopeMatches($0, role: scopeRole, scope: scope, controlRole: role, controlLabel: label) }
        } else {
            guard let windows = try attribute(application, kAXWindowsAttribute) as? [AXUIElement]
            else { throw FunctionalFailure.invalid("original windows") }
            let selected = try windows.filter { try matches($0, role: kAXWindowRole, label: windowTitle) }
            guard selected.count == 1 else { return nil }
            roots = scope.kind == "window" ? selected : try descendants(selected[0]).filter { try scopeMatches($0, role: scopeRole, scope: scope, controlRole: role, controlLabel: label) }
        }
        let innermost = try roots.filter { candidate in
            let descendants = try descendants(candidate)
            return !roots.contains { child in !CFEqual(child, candidate) && descendants.contains { CFEqual($0, child) } }
        }
        guard innermost.count <= 1 else { throw FunctionalFailure.invalid("ambiguous original scope") }
        guard let root = innermost.first else { return nil }
        let controls = try ([root] + descendants(root)).filter { try matches($0, role: role, label: label) }
        guard controls.count <= 1 else { throw FunctionalFailure.invalid("ambiguous original control") }
        return controls.first
    }

    private func scopeMatches(_ element: AXUIElement, role: String, scope: Step.Scope, controlRole: String, controlLabel: String) throws -> Bool {
        guard try attribute(element, kAXRoleAttribute) as? String == role else { return false }
        if !scope.label.isEmpty, try !matches(element, role: role, label: scope.label) { return false }
        guard let anchor = scope.anchor else { return true }
        guard let anchorRole = Self.roles[anchor.role], ["staticText", "button", "textField", "menuItem"].contains(anchor.role),
            !anchor.label.isEmpty, anchor.label.utf8.count <= 512
        else { throw FunctionalFailure.invalid("original scope source anchor") }
        let children = try descendants(element)
        guard try children.filter({ try matches($0, role: anchorRole, label: anchor.label) }).count == 1 else { return false }
        return try ([element] + children).filter({ try matches($0, role: controlRole, label: controlLabel) }).count == 1
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
        if label.isEmpty { return true }
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
        "slider": kAXSliderRole, "stepper": kAXIncrementorRole, "column": kAXColumnRole,
        "row": kAXRowRole, "staticText": kAXStaticTextRole, "textArea": kAXTextAreaRole,
    ]
    private static let scopes = [
        "window": kAXWindowRole, "sheet": kAXSheetRole, "menu": kAXMenuRole,
        "row": kAXRowRole, "panel": kAXWindowRole, "group": kAXGroupRole, "button": kAXButtonRole,
    ]
}
