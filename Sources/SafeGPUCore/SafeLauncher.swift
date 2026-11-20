import AppKit
import Foundation

public enum SafeLauncherError: LocalizedError {
    case appNotFound(URL)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .appNotFound(let url):
            return "Application not found at \(url.path)."
        case .launchFailed(let message):
            return "Could not launch application: \(message)"
        }
    }
}

@MainActor
public struct SafeLauncher {
    public init() {}

    public func runningInstances(for app: DiscoveredApp) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { running in
            if let runningURL = running.bundleURL?.standardizedFileURL, runningURL == app.bundleURL {
                return true
            }
            if !app.bundleIdentifier.hasPrefix("unknown."),
               let runningID = running.bundleIdentifier,
               runningID == app.bundleIdentifier {
                return true
            }
            return false
        }
    }

    public func isRunning(_ app: DiscoveredApp) -> Bool {
        !runningInstances(for: app).isEmpty
    }

    /// Gracefully terminates running instances of `app` and waits up to `timeout` seconds.
    public func terminate(_ app: DiscoveredApp, timeout: TimeInterval = 4.0) async -> Bool {
        let instances = runningInstances(for: app)
        guard !instances.isEmpty else { return true }

        for instance in instances {
            instance.terminate()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if runningInstances(for: app).isEmpty {
                return true
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return runningInstances(for: app).isEmpty
    }

    /// Launches `app` via `/usr/bin/open` using the exact same mechanism as SafeGPU wrappers.
    public func launchSafe(_ app: DiscoveredApp, preset: GPUPreset) throws {
        guard FileManager.default.fileExists(atPath: app.bundleURL.path) else {
            throw SafeLauncherError.appNotFound(app.bundleURL)
        }

        var args: [String] = []
        if app.engine == .qtWebEngine {
            args.append("--env")
            args.append("QTWEBENGINE_CHROMIUM_FLAGS=\(preset.flags.joined(separator: " "))")
        }
        args.append(contentsOf: ["-a", app.bundleURL.path, "--args"])
        args.append(contentsOf: preset.flags)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = args

        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw SafeLauncherError.launchFailed(error.localizedDescription)
        }

        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Exit code \(process.terminationStatus)"
            throw SafeLauncherError.launchFailed(errMsg)
        }
    }
}
