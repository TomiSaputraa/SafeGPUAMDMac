import Foundation
import Testing
@testable import SafeGPUCore

@Suite("AppDetector Tests")
struct AppDetectorTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("safegpu-detect-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func createFakeApp(
        in dir: URL,
        name: String,
        bundleID: String,
        executable: String = "AppBin",
        extraPlist: [String: Any] = [:],
        extraPaths: [String] = []
    ) throws -> URL {
        let fm = FileManager.default
        let appURL = dir.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)

        var plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name,
            "CFBundleExecutable": executable
        ]
        for (k, v) in extraPlist {
            plist[k] = v
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        for rel in extraPaths {
            let full = contents.appendingPathComponent(rel)
            if rel.hasSuffix("/") || rel.hasSuffix(".framework") || rel.hasSuffix(".app") {
                try fm.createDirectory(at: full, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: full.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("stub".utf8).write(to: full)
            }
        }
        return appURL
    }

    @Test("Detects Electron, Chromium, CEF, and QtWebEngine while ignoring native & wrapper apps")
    func autoScanDetection() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try createFakeApp(
            in: root,
            name: "Discord",
            bundleID: "com.hnc.Discord",
            extraPaths: ["Frameworks/Electron Framework.framework"]
        )
        try createFakeApp(
            in: root,
            name: "CustomElectron",
            bundleID: "com.example.asarapp",
            extraPaths: ["Resources/app.asar"]
        )
        try createFakeApp(
            in: root,
            name: "Brave Browser",
            bundleID: "com.brave.Browser",
            extraPaths: ["Frameworks/Brave Browser Framework.framework"]
        )
        try createFakeApp(
            in: root,
            name: "UnknownForkBrowser",
            bundleID: "org.custom.fork",
            extraPaths: ["Frameworks/Fork Framework.framework/Versions/Current/Libraries/libvk_swiftshader.dylib"]
        )
        try createFakeApp(
            in: root,
            name: "Spotify",
            bundleID: "com.spotify.client",
            extraPaths: ["Frameworks/Chromium Embedded Framework.framework"]
        )
        try createFakeApp(
            in: root,
            name: "QtBrowser",
            bundleID: "org.qt.sample",
            extraPaths: ["Frameworks/QtWebEngineCore.framework"]
        )
        try createFakeApp(
            in: root,
            name: "NativeNotes",
            bundleID: "com.example.native"
        )
        try createFakeApp(
            in: root,
            name: "SafeGPU",
            bundleID: AppDetector.safeGPUBundleID,
            extraPaths: ["Frameworks/Electron Framework.framework"]
        )
        try createFakeApp(
            in: root,
            name: "Discord (Safe)",
            bundleID: "com.safegpu.wrapper.com.hnc.discord",
            extraPlist: [AppDetector.wrapperInfoPlistKey: true],
            extraPaths: ["Frameworks/Electron Framework.framework"]
        )

        let detector = AppDetector(searchDirectories: [root])
        let found = detector.scanApplications()
        let map = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0.engine) })

        #expect(found.count == 6)
        #expect(map["Discord"] == .electron)
        #expect(map["CustomElectron"] == .electron)
        #expect(map["Brave Browser"] == .chromium)
        #expect(map["UnknownForkBrowser"] == .chromium)
        #expect(map["Spotify"] == .cef)
        #expect(map["QtBrowser"] == .qtWebEngine)
        #expect(map["NativeNotes"] == nil)
        #expect(map["SafeGPU"] == nil)
        #expect(map["Discord (Safe)"] == nil)
    }

    @Test("Allows adding non-Chromium apps manually with .manual engine")
    func manualAppAddition() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let nativeApp = try createFakeApp(
            in: root,
            name: "VyseTV",
            bundleID: "com.vyse.vyseTv"
        )

        let detector = AppDetector(searchDirectories: [root])
        let autoScan = detector.scanApplications()
        #expect(autoScan.isEmpty)

        let withManual = detector.scanApplications(manualAppPaths: [nativeApp.path])
        #expect(withManual.count == 1)
        #expect(withManual[0].name == "VyseTV")
        #expect(withManual[0].engine == .manual)
        #expect(withManual[0].isManuallyAdded == true)
    }
}
