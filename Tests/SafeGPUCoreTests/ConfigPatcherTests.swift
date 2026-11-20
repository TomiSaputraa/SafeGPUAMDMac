import Foundation
import Testing
@testable import SafeGPUCore

final class MockDefaultsAccess: DefaultsAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Bool] = [:]

    func readBool(domain: String, key: String) -> Bool? {
        lock.withLock { storage["\(domain)::\(key)"] }
    }

    func writeBool(domain: String, key: String, value: Bool) throws {
        lock.withLock { storage["\(domain)::\(key)"] = value }
    }

    func deleteKey(domain: String, key: String) throws {
        _ = lock.withLock { storage.removeValue(forKey: "\(domain)::\(key)") }
    }
}

@Suite("ConfigPatcher Tests")
struct ConfigPatcherTests {
    private func makeTempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("safegpu-patch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fakeApp(name: String, bundleID: String, engine: AppEngine) -> DiscoveredApp {
        DiscoveredApp(
            name: name,
            bundleIdentifier: bundleID,
            bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            executableName: name,
            engine: engine,
            isManuallyAdded: false
        )
    }

    @Test("Patches Chromium browser defaults and existing Local State, then reverts cleanly")
    func chromiumBrowserPatchAndRevert() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let defaults = MockDefaultsAccess()
        let patcher = ConfigPatcher(homeDirectory: home, defaults: defaults)
        let brave = fakeApp(name: "Brave Browser", bundleID: "com.brave.Browser", engine: .chromium)

        // Initially not patched
        #expect(patcher.status(for: brave).isSupported)
        #expect(!patcher.status(for: brave).isPatched)

        // Case 1: Local State doesn't exist yet -> patch writes defaults only without fabricating Local State
        try patcher.applyPatch(for: brave)
        #expect(defaults.readBool(domain: "com.brave.Browser", key: "HardwareAccelerationModeEnabled") == false)
        let localStateURL = home.appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser/Local State")
        #expect(!FileManager.default.fileExists(atPath: localStateURL.path))
        #expect(patcher.status(for: brave).isPatched)

        // Case 2: Local State now exists with hardware_acceleration_mode.enabled = true
        try FileManager.default.createDirectory(at: localStateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"profile":{"name":"Default"},"hardware_acceleration_mode":{"enabled":true}}"#.utf8).write(to: localStateURL)
        #expect(!patcher.status(for: brave).isPatched)

        try patcher.applyPatch(for: brave)
        #expect(patcher.status(for: brave).isPatched)

        let patchedData = try Data(contentsOf: localStateURL)
        let parsed = try JSONSerialization.jsonObject(with: patchedData) as? [String: Any]
        let hw = parsed?["hardware_acceleration_mode"] as? [String: Any]
        #expect(hw?["enabled"] as? Bool == false)
        #expect((parsed?["profile"] as? [String: Any])?["name"] as? String == "Default")

        // Revert
        try patcher.revertPatch(for: brave)
        #expect(!patcher.status(for: brave).isPatched)
        #expect(defaults.readBool(domain: "com.brave.Browser", key: "HardwareAccelerationModeEnabled") == nil)
    }

    @Test("Patches Discord settings.json even before first launch and preserves keys")
    func discordPatchAndRevert() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let patcher = ConfigPatcher(homeDirectory: home, defaults: MockDefaultsAccess())
        let discord = fakeApp(name: "Discord", bundleID: "com.hnc.Discord", engine: .electron)

        #expect(!patcher.status(for: discord).isPatched)
        try patcher.applyPatch(for: discord)
        #expect(patcher.status(for: discord).isPatched)

        let settingsURL = home.appendingPathComponent("Library/Application Support/discord/settings.json")
        #expect(FileManager.default.fileExists(atPath: settingsURL.path))

        try patcher.revertPatch(for: discord)
        #expect(!patcher.status(for: discord).isPatched)
    }

    @Test("Strips JSONC comments and trailing commas in VS Code / Antigravity argv.json")
    func vsCodeJSONCPatch() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let argvURL = home.appendingPathComponent(".vscode/argv.json")
        try FileManager.default.createDirectory(at: argvURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let jsonc = """
        // This configuration file allows you to pass permanent command line arguments to VS Code.
        /* Multi-line
           comment block */
        {
            "enable-crash-reporter": true,
            "homepage": "https://code.visualstudio.com//docs", // keep URL intact!
            "crash-reporter-id": "abc-123",
        }
        """
        try Data(jsonc.utf8).write(to: argvURL)

        let patcher = ConfigPatcher(homeDirectory: home, defaults: MockDefaultsAccess())
        let vscode = fakeApp(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode", engine: .electron)

        #expect(!patcher.status(for: vscode).isPatched)
        try patcher.applyPatch(for: vscode)
        #expect(patcher.status(for: vscode).isPatched)

        let data = try Data(contentsOf: argvURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["disable-hardware-acceleration"] as? Bool == true)
        #expect(obj?["crash-reporter-id"] as? String == "abc-123")
        #expect(obj?["homepage"] as? String == "https://code.visualstudio.com//docs")

        try patcher.revertPatch(for: vscode)
        #expect(!patcher.status(for: vscode).isPatched)
    }

    @Test("Patches Slack JSON and Spotify key=value prefs")
    func slackAndSpotifyPatch() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let patcher = ConfigPatcher(homeDirectory: home, defaults: MockDefaultsAccess())

        let slack = fakeApp(name: "Slack", bundleID: "com.tinyspeck.slackmacgap", engine: .electron)
        try patcher.applyPatch(for: slack)
        #expect(patcher.status(for: slack).isPatched)

        let spotify = fakeApp(name: "Spotify", bundleID: "com.spotify.client", engine: .cef)
        let prefsURL = home.appendingPathComponent("Library/Application Support/Spotify/prefs")
        try FileManager.default.createDirectory(at: prefsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("app.autologin=true\nui.hardware_acceleration=true\n".utf8).write(to: prefsURL)

        #expect(!patcher.status(for: spotify).isPatched)
        try patcher.applyPatch(for: spotify)
        #expect(patcher.status(for: spotify).isPatched)

        let updatedPrefs = try String(contentsOf: prefsURL, encoding: .utf8)
        #expect(updatedPrefs.contains("app.autologin=true"))
        #expect(updatedPrefs.contains("ui.hardware_acceleration=false"))

        try patcher.revertPatch(for: spotify)
        #expect(!patcher.status(for: spotify).isPatched)
    }

    @Test("Reports unsupported status for arbitrary Electron/Manual apps")
    func unsupportedApp() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let patcher = ConfigPatcher(homeDirectory: home, defaults: MockDefaultsAccess())
        let other = fakeApp(name: "RandomElectronApp", bundleID: "com.example.random", engine: .electron)

        #expect(patcher.status(for: other) == .unsupported)
        #expect(throws: ConfigPatchError.self) {
            try patcher.applyPatch(for: other)
        }
    }
}
