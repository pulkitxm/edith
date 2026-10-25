public struct HostPresentationReadiness: Equatable, Sendable {
    public let connected: Bool
    public let failed: Bool
    public let detached: Bool
    public let attached: Bool
    public let visible: Bool
    public let updating: Bool

    public init(
        connected: Bool, failed: Bool, detached: Bool, attached: Bool, visible: Bool,
        updating: Bool
    ) {
        self.connected = connected; self.failed = failed; self.detached = detached
        self.attached = attached; self.visible = visible; self.updating = updating
    }

    public var rejected: Bool { failed || detached || !attached }
    public var ready: Bool { !rejected && connected && visible && !updating }
}
