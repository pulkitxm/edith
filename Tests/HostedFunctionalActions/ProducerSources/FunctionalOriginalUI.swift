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
        let selector: String?
        let ownedLabel: OwnedLabel?
        let when: String?
        struct OwnedLabel: Decodable {
            let name: String
            let component: String
        }

        struct Scope: Decodable {
            let kind: String
            let label: String
            let anchor: Anchor?
            let ownedLabel: OwnedLabel?
            struct Anchor: Decodable {
                let role: String
                let label: String
                let selector: String?
                let ownedLabel: OwnedLabel?
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

    func perform(_ step: Step, deadline: ContinuousClock.Instant) async throws -> Bool {
        guard performed < 128, (!step.label.isEmpty || step.ownedLabel != nil || step.scope.anchor != nil), step.label.utf8.count <= 512,
            let role = Self.roles[step.role]
        else { throw FunctionalFailure.invalid("original control step") }
        try requireHeld()
        let control = try await wait(deadline: deadline) { try self.uniqueControl(role: role, label: step.label, scope: step.scope, selector: step.selector ?? "label") }
        try requireHeld()
        let secure = try attribute(control, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole
        guard step.role != "secureTextField" || secure,
            step.role != "textField" || !secure,
            try step.action == "choose-owned-path" || attribute(control, kAXEnabledAttribute) as? Bool == true
        else { throw FunctionalFailure.invalid("disabled original control") }
        try requireOwnedLabel(step.ownedLabel, actual: step.label)
        try requireOwnedLabel(step.scope.ownedLabel, actual: step.scope.label)
        if let anchor = step.scope.anchor { try requireOwnedLabel(anchor.ownedLabel, actual: anchor.label) }
        if let condition = step.when {
            let skip: Bool
            switch condition {
            case "value-differs":
                guard step.action == "set-checkbox", case .boolean(let desired) = step.value,
                    let current = try attribute(control, kAXValueAttribute) as? NSNumber,
                    current.intValue == 0 || current.intValue == 1
                else { throw FunctionalFailure.invalid("source checkbox condition") }
                skip = current.boolValue == desired
            case "not-selected":
                guard step.action == "click", let selected = try attribute(control, kAXSelectedAttribute) as? Bool
                else { throw FunctionalFailure.invalid("source selected condition") }
                skip = selected
            default: throw FunctionalFailure.invalid("source step condition")
            }
            if skip { performed += 1; try requireHeld(); return false }
        }
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
            guard ["textField", "secureTextField", "textArea"].contains(step.role), step.ownedPath == nil,
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
                ["Save", "Choose", "Open", "Scan"].contains(step.label)
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
        case ("set-column-width", .number(let width)):
            guard step.role == "column", width.isFinite, width >= 64, width <= 2048,
                let position = try attribute(control, kAXPositionAttribute),
                let size = try attribute(control, kAXSizeAttribute),
                CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
            else { throw FunctionalFailure.invalid("original column geometry") }
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
                AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions),
                dimensions.width > 0, dimensions.height >= 8, abs(dimensions.width - width) >= 1
            else { throw FunctionalFailure.invalid("original column must resize") }
            let start = CGPoint(x: point.x + dimensions.width - 1, y: point.y + 4)
            let end = CGPoint(x: start.x + width - dimensions.width, y: start.y)
            for (type, location) in [(CGEventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
                try requireHeld(); try host.requireCurrent()
                guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: location, mouseButton: .left)
                else { throw FunctionalFailure.invalid("original column native drag") }
                event.postToPid(host.pid)
            }
            _ = try await wait(deadline: deadline) {
                guard let value = try self.attribute(control, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
                var size = CGSize.zero
                guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgSize, &size) else { return nil }
                return abs(size.width - width) <= 2 ? control : nil
            }
        case ("show-menu", .null):
            guard ["row", "button", "staticText"].contains(step.role), step.ownedPath == nil,
                AXUIElementPerformAction(control, kAXShowMenuAction as CFString) == .success
            else { throw FunctionalFailure.invalid("original context menu") }
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
        return true
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

    private func requireOwnedLabel(_ label: Step.OwnedLabel?, actual: String) throws {
        guard let label else { return }
        guard label.component == "basename", let path = ownedPaths[label.name], path.url.lastPathComponent == actual
        else { throw FunctionalFailure.invalid("source-owned basename label") }
        try path.requireCurrent()
    }

    private func uniqueControl(role: String, label: String, scope: Step.Scope, selector: String = "label") throws -> AXUIElement? {
        guard let scopeRole = Self.scopes[scope.kind], !scope.label.isEmpty || scope.anchor != nil
        else { throw FunctionalFailure.invalid("original scope") }
        let roots: [AXUIElement]
        if scope.kind == "menu" || scope.kind == "panel" {
            roots = try descendants(application).filter { try scopeMatches($0, role: scopeRole, scope: scope, controlRole: role, controlLabel: label, controlSelector: selector) }
        } else {
            guard let windows = try attribute(application, kAXWindowsAttribute) as? [AXUIElement]
            else { throw FunctionalFailure.invalid("original windows") }
            let selected = try windows.filter { try matches($0, role: kAXWindowRole, label: windowTitle) }
            guard selected.count == 1 else { return nil }
            roots = scope.kind == "window" ? selected : try descendants(selected[0]).filter { try scopeMatches($0, role: scopeRole, scope: scope, controlRole: role, controlLabel: label, controlSelector: selector) }
        }
        let innermost = try roots.filter { candidate in
            let descendants = try descendants(candidate)
            return !roots.contains { child in !CFEqual(child, candidate) && descendants.contains { CFEqual($0, child) } }
        }
        guard innermost.count <= 1 else { throw FunctionalFailure.invalid("ambiguous original scope") }
        guard let root = innermost.first else { return nil }
        let controls = try ([root] + descendants(root)).filter { try matches($0, role: role, label: label, selector: selector) }
        guard controls.count <= 1 else { throw FunctionalFailure.invalid("ambiguous original control") }
        return controls.first
    }

    private func scopeMatches(_ element: AXUIElement, role: String, scope: Step.Scope, controlRole: String, controlLabel: String, controlSelector: String) throws -> Bool {
        guard try attribute(element, kAXRoleAttribute) as? String == role else { return false }
        if !scope.label.isEmpty, try !matches(element, role: role, label: scope.label) { return false }
        guard let anchor = scope.anchor else { return true }
        guard let anchorRole = Self.roles[anchor.role], ["staticText", "button", "textField", "menuItem"].contains(anchor.role),
            !anchor.label.isEmpty, anchor.label.utf8.count <= 512
        else { throw FunctionalFailure.invalid("original scope source anchor") }
        let children = try descendants(element)
        guard try children.filter({ try matches($0, role: anchorRole, label: anchor.label, selector: anchor.selector ?? "label") }).count == 1 else { return false }
        return try ([element] + children).filter({ try matches($0, role: controlRole, label: controlLabel, selector: controlSelector) }).count == 1
    }

    private func descendants(_ element: AXUIElement) throws -> [AXUIElement] {
        var pending = try attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        var output: [AXUIElement] = []
        var visited: [CFHashCode: [AXUIElement]] = [CFHash(element): [element]]
        while let current = pending.popLast() {
            let hash = CFHash(current)
            guard !visited[hash, default: []].contains(where: { CFEqual($0, current) }) else { continue }
            guard output.count < 10000 else { throw FunctionalFailure.invalid("accessibility inventory bound") }
            visited[hash, default: []].append(current)
            output.append(current)
            pending.append(contentsOf: try attribute(current, kAXChildrenAttribute) as? [AXUIElement] ?? [])
        }
        return output
    }

    private func matches(_ element: AXUIElement, role: String, label: String, selector: String = "label") throws -> Bool {
        guard try attribute(element, kAXRoleAttribute) as? String == role else { return false }
        guard ["label", "help", "placeholder"].contains(selector) else { throw FunctionalFailure.invalid("source selector") }
        if label.isEmpty { return true }
        if selector == "help" { return try attribute(element, kAXHelpAttribute) as? String == label }
        if selector == "placeholder" { return try attribute(element, kAXPlaceholderValueAttribute) as? String == label }
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
