import ServiceManagement

enum HostLoginItem {
    static func register() {
        let service = SMAppService.mainApp
        guard service.status != .enabled else { return }
        try? service.register()
    }
}
