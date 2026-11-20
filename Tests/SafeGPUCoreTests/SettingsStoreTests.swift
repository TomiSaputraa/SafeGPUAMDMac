import Foundation
import Testing
@testable import SafeGPUCore

@Suite("SettingsStore Tests")
struct SettingsStoreTests {
    @Test("Loads defaults when missing and persists settings across reloads")
    func roundTripSettings() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("safegpu-settings-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsFile = tempDir.appendingPathComponent("settings.json")
        let store = SettingsStore(fileURL: settingsFile, homeDirectory: tempDir)

        let initial = store.load()
        #expect(initial.wrapperDirectoryPath == tempDir.appendingPathComponent("Applications/SafeLaunch").path)
        #expect(initial.manualAppPaths.isEmpty)
        #expect(initial.presetByAppPath.isEmpty)

        var updated = initial
        updated.wrapperDirectoryPath = tempDir.appendingPathComponent("CustomWrappers").path
        updated.manualAppPaths = ["/Applications/Custom.app"]
        updated.presetByAppPath["/Applications/Discord.app"] = .swiftShader

        try store.save(updated)
        let reloaded = store.load()
        #expect(reloaded == updated)
    }
}
