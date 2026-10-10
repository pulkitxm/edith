import AppKit
import EdithHostCore
import EdithExtensionUI
import EdithExtensionSupport
import ExtensionFoundation
import ExtensionKit
import HostBootstrap
import SwiftUI

@_cdecl("edith_host_dispatch")
func dispatchHostEntry() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let explicitRole =
        arguments.first.map {
            $0.hasPrefix("--extension-") || $0.hasPrefix("--contained-extension-")
                || $0 == "--cli-fixture"
        } ?? false
    if Bundle.main.bundleURL.pathExtension == "appex", !explicitRole,
        ProcessInfo.processInfo.environment["EDITH_CLI"] != "1"
    {
        return
    }
    MainActor.assumeIsolated { HostEntry.runHost() }
    exit(0)
}

@main
struct HostEntry: AppExtension {
    init() { edith_host_bootstrap_anchor() }

    var configuration: AppExtensionSceneConfiguration {
        HostRemoteApplication.shared.sceneConfiguration
    }

    @MainActor static func runHost() {
        signal(SIGPIPE, SIG_IGN)
        let arguments = Array(CommandLine.arguments.dropFirst())
        if ProcessInfo.processInfo.environment["EDITH_CLI"] == "1"
            || (!arguments.isEmpty && !arguments[0].hasPrefix("--extension-")
                && !arguments[0].hasPrefix("--contained-extension-")
                && arguments[0] != "--cli-fixture")
        {
            exit(HostCLI.run(arguments))
        }
        #if EDITH_CLI_FIXTURE
        if arguments.count == 2, arguments[0] == "--extension-remote-fixture" {
            do { try HostRemoteFixture.run(directory: URL(fileURLWithPath: arguments[1])) } catch {
                exit(1)
            }
            return
        }
        if arguments == ["--extension-remote-fixture-engine"],
            Bundle.main.bundleIdentifier?.hasPrefix("com.pulkit.edith.tests.remote-") == true
        {
            do { try HostRemoteFixtureEngine().run() } catch { exit(1) }
            return
        }
        if arguments.count == 3, arguments[0] == "--extension-core-fixture",
            ["normal", "owner-exit"].contains(arguments[2])
        {
            do {
                try HostCoreFixture.run(
                    directory: URL(fileURLWithPath: arguments[1]),
                    orphan: arguments[2] == "owner-exit")
            } catch { exit(1) }
            return
        }
        if arguments.count == 2, arguments[0] == "--cli-fixture",
            Bundle.main.bundleIdentifier?.hasPrefix("com.pulkit.edith.tests.cli-") == true
        {
            do { try HostCLIFixture.run(directory: URL(fileURLWithPath: arguments[1])) } catch {
                exit(1)
            }
            return
        }
        #endif
        if arguments == ["--extension-ui-carrier"] {
            let application = NSApplication.shared
            let delegate = HostUICarrierDelegate()
            application.setActivationPolicy(.prohibited)
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
            return
        }
        do { if try HostContainedRole.run(arguments: arguments) { return } } catch {
            FileHandle.standardError.write(
                Data("The contained extension could not start: \(error).\n".utf8))
            exit(1)
        }
        guard
            HostContract.permitsLaunching(
                identifier: Bundle.main.bundleIdentifier, bundleURL: Bundle.main.bundleURL)

        else {
            FileHandle.standardError.write(
                Data("Install Edith in /Applications before starting the release app.\n".utf8))
            exit(1)
        }
        if arguments.count == 2,
            ["--extension-carrier-worker", "--extension-privileged-fixture"].contains(arguments[0])
        {
            do {
                try HostPrivilegedWorker(
                    bundle: URL(fileURLWithPath: arguments[1]),
                    fixture: arguments[0] == "--extension-privileged-fixture"
                ).run()
            } catch { exit(1) }
            return
        }
        if arguments == ["--extension-carrier"] {
            do { try HostPrivilegedCarrier(approved: true).run() } catch { exit(1) }
            return
        }
        if arguments.count == 2, arguments[0] == "--extension-native-task" {
            do { exit(try HostNativeTask.run(encoded: arguments[1])) } catch {
                FileHandle.standardError.write(
                    Data("The installed extension task could not start.\n".utf8))
                exit(1)
            }
        }
        if arguments == ["--extension-command"] {
            do { try ExtensionCommandSpecification.runWrapper() } catch { exit(1) }
        }
        if arguments == ["--extension-core"] {
            do { try HostCoreServiceRole.run() } catch { exit(1) }
            return
        }
        if arguments == ["--extension-worker"] {
            setenv("EDITH_EXTENSION_WORKER", "1", 1)
            guard setpgid(0, 0) == 0 || getpgrp() == getpid() else { exit(1) }
            do {
                let worker = try HostWorkerApplication()
                worker.run()
            } catch { exit(1) }
            return
        }
        guard arguments.isEmpty else { exit(HostCLI.run(arguments)) }
        HostApplication.main()
    }
}

private final class HostUICarrierDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NSApplication.shared.terminate(nil)
        }
    }
}
