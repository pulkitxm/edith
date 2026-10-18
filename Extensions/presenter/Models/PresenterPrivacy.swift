import EdithExtensionSupport
import Foundation

public enum PresenterPrivacy: String, CaseIterable, Hashable, Identifiable, Sendable {
    case music
    case money
    case usage
    case calendar
    case agents
    case attention
    case camera
    case studio
    case database
    case memory
    case fleet
    case review
    case siteAudit
    case runningApps
    case shelf
    case browser

    public var id: String { rawValue }

    public var storageKey: String {
        switch self {
        case .music: AppStorageKeys.Presenter.blurMusic
        case .money: AppStorageKeys.Presenter.blurMoney
        case .usage: AppStorageKeys.Presenter.blurUsage
        case .calendar: AppStorageKeys.Presenter.blurCalendar
        case .agents: AppStorageKeys.Presenter.blurAgents
        case .attention: AppStorageKeys.Presenter.blurAttention
        case .camera: AppStorageKeys.Presenter.blurCamera
        case .studio: AppStorageKeys.Presenter.blurStudio
        case .database: AppStorageKeys.Presenter.blurDatabase
        case .memory: AppStorageKeys.Presenter.blurMemory
        case .fleet: AppStorageKeys.Presenter.blurFleet
        case .review: AppStorageKeys.Presenter.blurReview
        case .siteAudit: AppStorageKeys.Presenter.blurSiteAudit
        case .runningApps: AppStorageKeys.Presenter.blurRunningApps
        case .shelf: AppStorageKeys.Presenter.blurShelf
        case .browser: AppStorageKeys.Presenter.blurBrowser
        }
    }

    public var fallback: Bool {
        self != .usage
    }

    public var title: String {
        switch self {
        case .music: "Blur music"
        case .money: "Blur cost figures"
        case .usage: "Blur usage figures"
        case .calendar: "Blur calendar events"
        case .agents: "Blur agents"
        case .attention: "Blur attention"
        case .camera: "Blur virtual camera"
        case .studio: "Blur studio"
        case .database: "Blur database"
        case .memory: "Blur memory"
        case .fleet: "Blur fleet"
        case .review: "Blur review"
        case .siteAudit: "Blur site audit"
        case .runningApps: "Blur running apps"
        case .shelf: "Blur shelf files"
        case .browser: "Blur notch browser"
        }
    }

    public var summary: String {
        switch self {
        case .music: "Blur track names, artwork and folders."
        case .money: "Blur spend figures."
        case .usage: "Blur usage percentages."
        case .calendar: "Blur calendar entries."
        case .agents: "Hide live Herdr titles and blur attached terminals."
        case .attention: "Blur attention activity, titles and sites."
        case .camera: "Blur the virtual camera picture and personal backdrops."
        case .studio: "Blur Studio files, projects and previews."
        case .database: "Blur database connections and rows."
        case .memory: "Blur memory chats, notes and captures."
        case .fleet: "Blur machine names, files and terminals."
        case .review: "Blur review sessions."
        case .siteAudit: "Blur site audit projects and pages."
        case .runningApps: "Blur running app names and icons."
        case .shelf: "Blur files parked on the shelf."
        case .browser: "Blur the notch browser, including the address and page titles."
        }
    }

    public func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: storageKey) as? Bool ?? fallback
    }

    public func hides(active: Bool, defaults: UserDefaults) -> Bool {
        active && isEnabled(in: defaults)
    }
}
