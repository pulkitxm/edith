import AppKit
import Combine
import EdithKit
import Foundation

enum InstallerPhase: Equatable {
    case license
    case downloading
    case done
    case failure(InstallerFailure)
}

enum InstallerFailure: Equatable {
    case network
    case serverUnavailable
    case server(statusCode: Int)
    case invalidDownload
    case fileSystem
    case opening

    var title: String {
        switch self {
        case .network:
            "Download interrupted"
        case .serverUnavailable:
            "Download unavailable"
        case .server:
            "Download failed"
        case .invalidDownload:
            "Invalid download"
        case .fileSystem:
            "Could not save Edith"
        case .opening:
            "Could not open Edith"
        }
    }

    var message: String {
        switch self {
        case .network:
            "Check your connection and try again."
        case .serverUnavailable:
            "The download service is temporarily unavailable (502)."
        case let .server(statusCode):
            "The download server returned error \(statusCode)."
        case .invalidDownload:
            "The server did not return a valid Edith installer image."
        case .fileSystem:
            "Edith.dmg could not be written to your Downloads folder."
        case .opening:
            "Edith.dmg is in your Downloads folder. Open it there or try again."
        }
    }
}

@MainActor
final class InstallerModel: ObservableObject {
    @Published private(set) var key = "EDITH-"
    @Published private(set) var phase = InstallerPhase.license
    @Published private(set) var errorMessage: String?
    @Published private(set) var seatLimitHit = false
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var activating = false

    private let client: LicenseClient
    private var downloader: InstallerDownloader?
    private var downloadedDMG: URL?

    init(client: LicenseClient = LicenseClient()) {
        self.client = client
    }

    var canActivate: Bool {
        LicenseKeyFormatting.isComplete(key)
    }

    var activationButtonTitle: String {
        errorMessage == nil ? "Activate" : "Retry"
    }

    func updateKey(_ value: String) {
        key = LicenseKeyFormatting.format(value)
        errorMessage = nil
        seatLimitHit = false
    }

    func activate() {
        guard phase == .license, canActivate, !activating else { return }
        guard let machine = hardwareUUID() else {
            errorMessage = "This Mac could not be identified."
            return
        }
        errorMessage = nil
        seatLimitHit = false
        activating = true
        let formattedKey = LicenseKeyFormatting.format(key)
        Task {
            defer { activating = false }
            do {
                let response = try await client.activate(
                    key: formattedKey,
                    hardwareUuid: machine
                )
                guard response.ok else {
                    errorMessage = "That license key is invalid or inactive."
                    return
                }
                startDownload(key: formattedKey, machine: machine)
            } catch LicenseClientError.seatLimitReached {
                errorMessage = "This key has reached its Mac limit."
                seatLimitHit = true
            } catch LicenseClientError.machineLimitReached(let machinesUsed, let maxMachines) {
                errorMessage =
                    "This key is already active on \(machinesUsed) of \(maxMachines) Macs."
                seatLimitHit = true
            } catch LicenseClientError.invalidKey {
                errorMessage = "That license key is invalid or inactive."
            } catch LicenseClientError.server(statusCode: 502) {
                errorMessage = "The license service is temporarily unavailable (502)."
            } catch LicenseClientError.server(let statusCode) {
                errorMessage = "The license service returned error \(statusCode)."
            } catch LicenseClientError.invalidResponse {
                errorMessage = "The license service returned an invalid response."
            } catch {
                errorMessage = "Could not activate. Check your connection and try again."
            }
        }
    }

    func retry() {
        if case .failure(.opening) = phase, let downloadedDMG {
            phase = .done
            openDownloadedDMG(downloadedDMG)
            return
        }
        phase = .license
        activate()
    }

    private func startDownload(key: String, machine: String) {
        phase = .downloading
        downloadProgress = nil
        let downloader = InstallerDownloader()
        self.downloader = downloader
        downloader.start(
            key: key,
            machine: machine,
            onProgress: { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress
                }
            },
            completion: { [weak self] result in
                Task { @MainActor in
                    self?.downloadFinished(result)
                }
            }
        )
    }

    private func downloadFinished(_ result: Result<URL, InstallerDownloadError>) {
        downloader = nil
        switch result {
        case let .success(url):
            downloadedDMG = url
            phase = .done
            openDownloadedDMG(url)
        case .failure(.network):
            phase = .failure(.network)
        case .failure(.server(statusCode: 502)):
            phase = .failure(.serverUnavailable)
        case let .failure(.server(statusCode)):
            phase = .failure(.server(statusCode: statusCode))
        case .failure(.invalidResponse):
            phase = .failure(.invalidDownload)
        case .failure(.fileSystem):
            phase = .failure(.fileSystem)
        }
    }

    private func openDownloadedDMG(_ url: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            guard NSWorkspace.shared.open(url) else {
                phase = .failure(.opening)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSApp.terminate(nil)
            }
        }
    }
}

enum InstallerDownloadError: Error {
    case network
    case server(statusCode: Int)
    case invalidResponse
    case fileSystem
}

final class InstallerDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var session: URLSession?
    private var onProgress: ((Double?) -> Void)?
    private var completion: ((Result<URL, InstallerDownloadError>) -> Void)?
    private var completed = false

    func start(
        key: String,
        machine: String,
        onProgress: @escaping (Double?) -> Void,
        completion: @escaping (Result<URL, InstallerDownloadError>) -> Void
    ) {
        self.onProgress = onProgress
        self.completion = completion
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(
            url: URL(string: "https://edith.pulkit.page/api/v1/download/dmg")!)
        request.setValue(key, forHTTPHeaderField: "x-edith-license")
        request.setValue(machine, forHTTPHeaderField: "x-edith-machine")
        session.downloadTask(with: request).resume()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else {
            onProgress?(nil)
            return
        }
        onProgress?(min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let response = downloadTask.response as? HTTPURLResponse else {
            finish(.failure(.invalidResponse))
            return
        }
        guard (200..<300).contains(response.statusCode) else {
            finish(.failure(.server(statusCode: response.statusCode)))
            return
        }
        guard let filename = response.suggestedFilename,
            filename.range(of: #"^Edith-v[^/]+\.dmg$"#, options: .regularExpression) != nil
        else {
            finish(.failure(.invalidResponse))
            return
        }
        do {
            let fileManager = FileManager.default
            let downloadDirectories = fileManager.urls(
                for: .downloadsDirectory, in: .userDomainMask)
            let downloads =
                downloadDirectories.first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
                    "Downloads", isDirectory: true)
            try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
            let destination = downloads.appendingPathComponent("Edith.dmg")
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(.fileSystem))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard error != nil else { return }
        finish(.failure(.network))
    }

    private func finish(_ result: Result<URL, InstallerDownloadError>) {
        guard !completed else { return }
        completed = true
        completion?(result)
        session?.finishTasksAndInvalidate()
    }
}
