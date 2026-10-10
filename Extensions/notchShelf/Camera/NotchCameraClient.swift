import AVFoundation
import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation
import SwiftUI

@MainActor @Observable final class NotchCameraClient {
    typealias Invoke = @MainActor (NotchCameraRequest.Operation, String?) async throws -> Data
    private(set) var state: NotchCameraState?
    private(set) var error: String?
    private(set) var image: NSImage?
    private let invoke: Invoke
    private var generation = UUID()
    private var stopped = false
    private var task: Task<Void, Never>?
    private var readAgain = false
    private var actions: [(NotchCameraRequest.Operation, String?)] = []
    @ObservationIgnored private nonisolated(unsafe) var observer: NSObjectProtocol?
    init(namespace: String, presentationID: UUID, invoke: @escaping Invoke) {
        self.invoke = invoke
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(namespace + ".notchCamera." + presentationID.uuidString),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.perform(.read) }
        }
    }
    deinit { if let observer { DistributedNotificationCenter.default().removeObserver(observer) } }
    func perform(_ operation: NotchCameraRequest.Operation, deviceID: String? = nil) {
        guard !stopped else { return }
        if task != nil {
            if operation == .read {
                readAgain = true
            } else if actions.count < 4 {
                actions.append((operation, deviceID))
            } else {
                error = "The camera control queue is full."
            }
            return
        }
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == token { task = nil } }
            var operation = operation
            var selectedDevice = deviceID
            repeat {
                readAgain = false
                do {
                    let data = try await invoke(operation, selectedDevice)
                    try Task.checkCancellation()
                    guard !stopped, generation == token, data.count <= 786432 else { return }
                    let next = try JSONDecoder().decode(NotchCameraState.self, from: data)
                    guard AVAuthorizationStatus(rawValue: next.authorization) != nil,
                        next.devices.count <= 32,
                        next.frame.map({ $0.count <= 524288 }) ?? true
                    else { throw ExtensionPeerError.invalidRequest }
                    state = next; image = next.frame.flatMap(NSImage.init(data:));
                    error = next.error
                } catch {
                    if !stopped, generation == token, !Task.isCancelled {
                        self.error = error.localizedDescription
                    }
                }
                if !actions.isEmpty {
                    (operation, selectedDevice) = actions.removeFirst()
                } else if readAgain {
                    operation = .read; selectedDevice = nil
                } else {
                    break
                }
            } while !Task.isCancelled && !stopped
        }
    }
    func load() async {
        perform(.read)
        await task?.value
        if state?.authorization == AVAuthorizationStatus.authorized.rawValue {
            perform(.start); await task?.value
        }
    }
    func cycle() {
        guard let state, state.devices.count > 1 else { return }
        let desired = actions.last(where: { $0.0 == .select })?.1 ?? state.selectedID
        let index = state.devices.firstIndex(where: { $0.id == desired }) ?? 0
        perform(.select, deviceID: state.devices[(index + 1) % state.devices.count].id)
    }
    func drain() async { await task?.value }
    func stop() {
        generation = UUID(); stopped = true; task?.cancel(); task = nil; state = nil; image = nil
        actions = []; readAgain = false
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
    }
}

struct NotchRemoteCameraTab: View {
    let model: NotchCameraClient
    @Environment(\.automaticViewActionsEnabled) private var automaticActions
    var body: some View {
        Group {
            if model.state?.authorization == AVAuthorizationStatus.authorized.rawValue {
                GeometryReader { geometry in
                    ZStack {
                        Color.black
                        if let image = model.image, !NotchPresenterState.shared.hides(.camera) {
                            Image(nsImage: image).resizable().scaledToFill().scaleEffect(
                                x: -1, y: 1
                            )
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                        }
                    }.overlay(alignment: .bottomTrailing) {
                        if (model.state?.devices.count ?? 0) > 1 {
                            Button {
                                model.cycle()
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath.camera").font(
                                    .system(size: 13, weight: .medium)
                                )
                                .foregroundStyle(.white).frame(width: 32, height: 32)
                                .background(.black.opacity(0.55), in: Circle()).contentShape(
                                    Circle())
                            }.buttonStyle(.edith(.borderless)).padding(14).help("Switch camera")
                        }
                    }
                }
            } else if model.state?.authorization == AVAuthorizationStatus.notDetermined.rawValue {
                VStack(spacing: 8) {
                    Image(systemName: "camera.fill").font(.system(size: 20)).foregroundStyle(
                        .white.opacity(0.7))
                    Text("Mirror check, right in the notch").font(
                        .system(size: 12, weight: .semibold)
                    ).foregroundStyle(.white.opacity(0.9))
                    Text("macOS asks for camera access once. Nothing is recorded or sent anywhere.")
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                    HStack(spacing: 8) {
                        Button("Allow Camera") { model.perform(.permission) }.buttonStyle(
                            .edith(.primary)
                        ).controlSize(.small)
                        Button("All Permissions") { model.perform(.privacy) }.buttonStyle(
                            .edith(.borderless)
                        )
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    }.padding(.top, 2)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.state != nil {
                Button {
                    model.perform(.privacy)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "camera.metering.none").font(.system(size: 20))
                        Text("Camera access is off").font(.system(size: 12))
                        Text("Open System Settings").font(.system(size: 10)).foregroundStyle(
                            .white.opacity(0.5))
                    }.foregroundStyle(.white.opacity(0.7)).frame(
                        maxWidth: .infinity, maxHeight: .infinity)
                }.buttonStyle(.edith(.borderless))
            } else {
                Color.black
            }
        }.overlay(alignment: .bottom) {
            if let error = model.error {
                Text(error).font(.edithText(.caption)).foregroundStyle(.orange).padding(8)
            }
        }
        .task { if automaticActions { await model.load() } }
    }
}
