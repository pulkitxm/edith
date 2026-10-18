import EdithHostCore

extension HostHerdrNotificationRouter {
    convenience init(
        currentVersion: @escaping @MainActor () -> String?, navigation: HostWindowNavigation,
        preparedPresentation:
            @escaping @MainActor (String) async throws -> HostHerdrNotificationLease
    ) {
        self.init(currentVersion: currentVersion) { [weak navigation] version in
            guard let navigation else { throw HostWorkerError.rejected }
            try await navigation.navigate(extensionID: "herdr", version: version)
            try Task.checkCancellation()
            guard currentVersion() == version else { throw HostWorkerError.rejected }
            return try await preparedPresentation(version)
        }
    }
}
