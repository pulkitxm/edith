import EdithKit
import SwiftUI

struct FocusView: View {
    let runtime: FocusRuntime

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if let session = runtime.activeSession {
                    activeCard(session)
                } else if runtime.document.profiles.isEmpty {
                    ContentUnavailableView(
                        "No focus profiles yet", systemImage: "moon.stars",
                        description: Text("Create a profile in Edith settings and connect scenes.")
                    )
                    .frame(minHeight: 180)
                } else {
                    ForEach(runtime.document.profiles) { profile in
                        profileCard(profile)
                    }
                }
                if runtime.document.meeting.isEnabled {
                    HStack(spacing: 8) {
                        Image(systemName: "video.fill")
                        Text("Meeting Mode watches the next Calendar boundary")
                        Spacer()
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                if let error = runtime.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let latest = runtime.history.last {
                    HStack {
                        Label("Last session", systemImage: "clock.arrow.circlepath")
                        Spacer()
                        Text("\(latest.profileName) · \(latest.outcome.rawValue.capitalized)")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 210, maxHeight: 390)
    }

    private func activeCard(_ session: FocusSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: session.origin == .meeting ? "video.fill" : "moon.stars.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.profileName)
                        .font(.system(size: 14, weight: .semibold))
                    Text(session.origin == .meeting ? "Meeting Mode" : "Focus active")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("End & Restore") { runtime.stop() }
                    .buttonStyle(.edith(.primary))
            }
            if let endsAt = session.endsAt {
                ProgressView(
                    timerInterval: session
                        .startedAt...max(endsAt, session.startedAt.addingTimeInterval(1)),
                    countsDown: true
                )
                .progressViewStyle(.linear)
                Text("Ends \(endsAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Text("Runs until you end it. Edith will restore captured settings and app state.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }

    private func profileCard(_ profile: FocusProfile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "moon.stars")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(
                    profile.isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
                )
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail(profile))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Start") {
                Button("Default") { runtime.start(profile, origin: .menuPanel) }
                Button("25 minutes") {
                    runtime.start(profile, durationMinutes: 25, origin: .menuPanel)
                }
                Button("50 minutes") {
                    runtime.start(profile, durationMinutes: 50, origin: .menuPanel)
                }
                Button("Until stopped") {
                    runtime.start(profile, durationMinutes: nil, origin: .menuPanel)
                }
            }
            .menuStyle(.borderlessButton)
            .disabled(!profile.isEnabled)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func detail(_ profile: FocusProfile) -> String {
        let scenes = profile.sceneIDs.count + (profile.windowLayoutSceneID == nil ? 0 : 1)
        let duration = profile.defaultDurationMinutes.map { "\($0)m" } ?? "until stopped"
        return "\(scenes) scenes · \(profile.launchApplicationIDs.count) launch · \(duration)"
    }
}
