import EdithKit
import Foundation
import UserNotifications

@MainActor
final class AgentNotificationPresentationBridge {
    static let shared = AgentNotificationPresentationBridge()
    private var observer: NSObjectProtocol?
    private var task: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var pending = false
    private let delegate = LimitNotifier.shared

    func start() {
        guard observer == nil else { return }
        observer = IPC.observe(AgentNotificationOperation.changed) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
        retry = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch { return }
                self?.refresh()
            }
        }
    }

    func refresh() {
        guard task == nil else {
            pending = true
            return
        }
        task = Task { [weak self] in
            repeat {
                self?.pending = false
                _ = await AgentNotificationDeliveryWorker.deliverPending()
            } while self?.pending == true && !Task.isCancelled
            self?.task = nil
        }
    }
}

enum AgentNotificationDeliveryWorker {
    static func deliverPending(
        load: @escaping @Sendable () throws -> [AgentNotificationDelivery] = {
            try AgentNotificationClient.pending()
        },
        present: @escaping @Sendable (AgentNotificationDelivery) async throws -> Void = {
            try await AgentNotificationDeliveryWorker.present($0)
        },
        acknowledge: @escaping @Sendable ([UUID]) throws -> Void = {
            try AgentNotificationClient.acknowledge($0)
        }
    ) async -> Bool {
        guard let deliveries = try? await AgentQuery.value(load).get() else { return false }
        var accepted: [UUID] = []
        for delivery in deliveries {
            guard !Task.isCancelled else { break }
            do {
                try await present(delivery)
                accepted.append(delivery.id)
            } catch {
                NSLog("Edith notification presentation failed: %@", error.localizedDescription)
            }
        }
        guard !accepted.isEmpty else { return deliveries.isEmpty }
        let ids = accepted
        do {
            try await AgentQuery.value { try acknowledge(ids) }.get()
            return accepted.count == deliveries.count
        } catch { return false }
    }

    static func present(_ delivery: AgentNotificationDelivery) async throws {
        let center = UNUserNotificationCenter.current()
        guard let notification = delivery.notification,
            (delivery.expiresAt ?? .distantFuture) > Date()
        else {
            center.removePendingNotificationRequests(withIdentifiers: [delivery.identifier])
            return
        }
        let authorization = await center.notificationSettings().authorizationStatus
        guard authorization == .authorized || authorization == .provisional else {
            throw AgentError(.unavailable, "Notification permission has not been granted.")
        }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        let trigger: UNNotificationTrigger?
        if let fireAt = delivery.fireAt, fireAt > Date() {
            trigger = UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second], from: fireAt),
                repeats: false)
        } else {
            trigger = nil
        }
        try await center.add(
            UNNotificationRequest(
                identifier: delivery.identifier, content: content, trigger: trigger))
    }
}
