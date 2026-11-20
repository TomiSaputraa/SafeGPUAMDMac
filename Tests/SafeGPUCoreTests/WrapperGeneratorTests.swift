import Foundation
import Testing
@testable import SafeGPUCore

@Suite("WrapperGenerator Tests")
struct WrapperGeneratorTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("safegpu-wrapper-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Generates Wrapper .app with Info.plist, executable script, badged .icns, and updates/deletes cleanly")
    func generateUpdateAndDeleteWrapper() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let targetAppDir = root.appendingPathComponent("My 'Cool' App.app", isDirectory: true)
        try FileManager.default.createDirectory(at: targetAppDir.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let targetApp = DiscoveredApp(
            name: "My 'Cool' App",
            bundleIdentifier: "com.example.coolapp",
            bundleURL: targetAppDir,
            executableName: "CoolApp",
            engine: .electron,
            isManuallyAdded: false
        )

        let outputDir = root.appendingPathComponent("SafeLaunch", isDirectory: true)
        let generator = WrapperGenerator()

        #expect(generator.wrapperStatus(for: targetApp, in: outputDir) == .notCreated)

        let wrapperURL = try generator.generateWrapper(
            for: targetApp,
            preset: .strict,
            in: outputDir,
            generateIcon: true,
            codesign: false
        )

        #expect(wrapperURL.lastPathComponent == "My 'Cool' App (Safe).app")
        #expect(FileManager.default.fileExists(atPath: wrapperURL.path))

        // Verify Info.plist metadata
        let plistURL = wrapperURL.appendingPathComponent("Contents/Info.plist")
        let plistData = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        #expect(plist?[AppDetector.wrapperInfoPlistKey] as? Bool == true)
        #expect(plist?[WrapperGenerator.targetPathPlistKey] as? String == targetApp.bundleURL.path)
        #expect(plist?[WrapperGenerator.presetPlistKey] as? String == GPUPreset.strict.rawValue)
        #expect(plist?["LSUIElement"] as? Bool == true)

        // Verify launcher script is executable and properly quoted
        let scriptURL = wrapperURL.appendingPathComponent("Contents/MacOS/launcher")
        #expect(FileManager.default.isExecutableFile(atPath: scriptURL.path))
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        #expect(script.contains("'--disable-gpu' '--disable-gpu-compositing'"))
        #expect(script.contains("'\\''Cool'\\''"))

        // Verify badged .icns icon was actually created and non-empty
        let iconURL = wrapperURL.appendingPathComponent("Contents/Resources/AppIcon.icns")
        let iconAttrs = try FileManager.default.attributesOfItem(atPath: iconURL.path)
        let iconSize = (iconAttrs[.size] as? NSNumber)?.intValue ?? 0
        #expect(iconSize > 1000)

        // Verify status detection
        let status = generator.wrapperStatus(for: targetApp, in: outputDir)
        #expect(status == .ready(url: wrapperURL, preset: .strict))

        // Verify AppDetector ignores generated wrapper even if scanning SafeLaunch directly
        let detector = AppDetector(searchDirectories: [outputDir])
        #expect(detector.scanApplications().isEmpty)

        // Update preset to swiftShader
        try generator.generateWrapper(
            for: targetApp,
            preset: .swiftShader,
            in: outputDir,
            generateIcon: false,
            codesign: false
        )
        let updatedStatus = generator.wrapperStatus(for: targetApp, in: outputDir)
        #expect(updatedStatus == .ready(url: wrapperURL, preset: .swiftShader))

        // Delete wrapper
        try generator.deleteWrapper(for: targetApp, in: outputDir)
        #expect(generator.wrapperStatus(for: targetApp, in: outputDir) == .notCreated)
    }

    @Test("Includes QTWEBENGINE_CHROMIUM_FLAGS env var for QtWebEngine apps")
    func qtWebEngineScriptIncludesEnvFlag() {
        let qtApp = DiscoveredApp(
            name: "QtApp",
            bundleIdentifier: "org.qt.app",
            bundleURL: URL(fileURLWithPath: "/Applications/QtApp.app"),
            executableName: "QtApp",
            engine: .qtWebEngine,
            isManuallyAdded: false
        )

        let script = WrapperGenerator.buildLauncherScript(for: qtApp, preset: .strict)
        #expect(script.contains("--env 'QTWEBENGINE_CHROMIUM_FLAGS=--disable-gpu --disable-gpu-compositing'"))
    }
}
