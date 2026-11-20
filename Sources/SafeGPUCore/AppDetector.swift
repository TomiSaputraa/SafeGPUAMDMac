import Foundation

public struct AppDetector: Sendable {
    public static let safeGPUBundleID = "com.safegpu.app"
    public static let wrapperInfoPlistKey = "SafeGPUWrapper"

    public static let knownChromiumBrowserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.google.Chrome.dev",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary",
        "com.vivaldi.Vivaldi",
        "com.vivaldi.Vivaldi.snapshot",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaGX",
        "com.operasoftware.OperaDeveloper",
        "org.chromium.Chromium",
        "company.thebrowser.Browser",
        "company.thebrowser.dia",
        "org.thorium.Thorium",
        "com.sigmaos.sigmaos.macos",
        "ru.yandex.desktop.yandex-browser"
    ]

    public let searchDirectories: [URL]

    public init(
        searchDirectories: [URL]? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        if let searchDirectories {
            self.searchDirectories = searchDirectories
        } else {
            self.searchDirectories = [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                homeDirectory.appendingPathComponent("Applications", isDirectory: true)
            ]
        }
    }

    public func scanApplications(manualAppPaths: [String] = []) -> [DiscoveredApp] {
        var discoveredByPath: [String: DiscoveredApp] = [:]
        let fm = FileManager.default

        for dir in searchDirectories {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for item in items {
                guard item.pathExtension.lowercased() == "app" else { continue }
                if let app = inspectApp(at: item, isManuallyAdded: false) {
                    discoveredByPath[app.id] = app
                }
            }
        }

        for rawPath in manualAppPaths {
            let expanded = (rawPath as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded).standardizedFileURL
            if discoveredByPath[url.path] != nil {
                continue
            }
            if let app = inspectApp(at: url, isManuallyAdded: true) {
                discoveredByPath[app.id] = app
            }
        }

        return discoveredByPath.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public func inspectApp(at bundleURL: URL, isManuallyAdded: Bool) -> DiscoveredApp? {
        let fm = FileManager.default
        let standardized = bundleURL.standardizedFileURL

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: standardized.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }

        let infoPlistURL = standardized
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")

        guard
            let plistData = try? Data(contentsOf: infoPlistURL),
            let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        else {
            return nil
        }

        // Skip SafeGPU itself and generated wrappers
        if let isWrapper = plist[Self.wrapperInfoPlistKey] as? Bool, isWrapper {
            return nil
        }

        let bundleID = (plist["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if bundleID == Self.safeGPUBundleID {
            return nil
        }

        let executableName = (plist["CFBundleExecutable"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !executableName.isEmpty else {
            return nil
        }

        let detectedEngine = detectEngine(in: standardized, bundleIdentifier: bundleID)
        let finalEngine: AppEngine
        if let detectedEngine {
            finalEngine = detectedEngine
        } else if isManuallyAdded {
            finalEngine = .manual
        } else {
            return nil
        }

        let fileBaseName = standardized.deletingPathExtension().lastPathComponent
        let displayName: String
        if !fileBaseName.isEmpty {
            displayName = fileBaseName
        } else if let cfDisplay = plist["CFBundleDisplayName"] as? String, !cfDisplay.isEmpty {
            displayName = cfDisplay
        } else if let cfName = plist["CFBundleName"] as? String, !cfName.isEmpty {
            displayName = cfName
        } else {
            displayName = executableName
        }

        return DiscoveredApp(
            name: displayName,
            bundleIdentifier: bundleID.isEmpty ? "unknown.\(executableName.lowercased())" : bundleID,
            bundleURL: standardized,
            executableName: executableName,
            engine: finalEngine,
            isManuallyAdded: isManuallyAdded
        )
    }

    public func detectEngine(in bundleURL: URL, bundleIdentifier: String) -> AppEngine? {
        let fm = FileManager.default
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let frameworksURL = contentsURL.appendingPathComponent("Frameworks", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)

        // 1. Electron detection
        let electronIndicators = [
            frameworksURL.appendingPathComponent("Electron Framework.framework"),
            resourcesURL.appendingPathComponent("app.asar"),
            resourcesURL.appendingPathComponent("electron.asar")
        ]
        if electronIndicators.contains(where: { fm.fileExists(atPath: $0.path) }) {
            return .electron
        }

        // 2. CEF (Chromium Embedded Framework) detection
        let cefFramework = frameworksURL.appendingPathComponent("Chromium Embedded Framework.framework")
        if fm.fileExists(atPath: cefFramework.path) {
            return .cef
        }

        // 3. QtWebEngine detection
        let qtIndicators = [
            frameworksURL.appendingPathComponent("QtWebEngineCore.framework"),
            frameworksURL.appendingPathComponent("QtWebEngine.framework"),
            resourcesURL.appendingPathComponent("qtwebengine_resources.pak")
        ]
        if qtIndicators.contains(where: { fm.fileExists(atPath: $0.path) }) {
            return .qtWebEngine
        }

        // 4. Chromium browser / runtime detection
        if Self.knownChromiumBrowserBundleIDs.contains(bundleIdentifier) {
            return .chromium
        }

        if let frameworkEntries = try? fm.contentsOfDirectory(
            at: frameworksURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for entry in frameworkEntries {
                let name = entry.lastPathComponent
                if name.contains("Helper (GPU).app") {
                    return .chromium
                }
                guard entry.pathExtension == "framework" else { continue }

                // Check Chromium framework layout (e.g. Brave Browser Framework.framework, Google Chrome Framework.framework)
                let candidateRoots = [
                    entry,
                    entry.appendingPathComponent("Versions/Current", isDirectory: true)
                ]
                for root in candidateRoots {
                    let chromiumMarkers = [
                        root.appendingPathComponent("Libraries/libvk_swiftshader.dylib"),
                        root.appendingPathComponent("Resources/chrome_100_percent.pak"),
                        root.appendingPathComponent("Resources/icudtl.dat")
                    ]
                    if chromiumMarkers.contains(where: { fm.fileExists(atPath: $0.path) }) {
                        return .chromium
                    }
                    let helpersDir = root.appendingPathComponent("Helpers", isDirectory: true)
                    if let helpers = try? fm.contentsOfDirectory(atPath: helpersDir.path),
                       helpers.contains(where: { $0.contains("Helper (GPU).app") }) {
                        return .chromium
                    }
                }
            }
        }

        return nil
    }
}
