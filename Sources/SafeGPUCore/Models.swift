import Foundation

public enum AppEngine: String, Codable, Sendable, CaseIterable {
    case electron
    case chromium
    case cef
    case qtWebEngine
    case manual

    public var displayName: String {
        switch self {
        case .electron: return "Electron"
        case .chromium: return "Chromium"
        case .cef: return "CEF"
        case .qtWebEngine: return "QtWebEngine"
        case .manual: return "Manual / Other"
        }
    }

    public var shortLabel: String {
        switch self {
        case .electron: return "Electron"
        case .chromium: return "Chromium"
        case .cef: return "CEF"
        case .qtWebEngine: return "QtWebEngine"
        case .manual: return "Manual"
        }
    }
}

public enum GPUPreset: String, Codable, Sendable, CaseIterable {
    case standard
    case strict
    case swiftShader

    public var displayName: String {
        switch self {
        case .standard:
            return "Standard"
        case .strict:
            return "Strict (No Compositing)"
        case .swiftShader:
            return "SwiftShader (Software WebGL)"
        }
    }

    public var descriptionText: String {
        switch self {
        case .standard:
            return "Disables GPU hardware acceleration. Best default for most Chromium & Electron apps."
        case .strict:
            return "Also disables GPU compositing. Use this if windows still flicker, show black screens, or freeze macOS."
        case .swiftShader:
            return "Forces ANGLE SwiftShader software rendering. Best for WebGL/Canvas apps (e.g., Discord, Figma, Maps)."
        }
    }

    public var flags: [String] {
        switch self {
        case .standard:
            return ["--disable-gpu"]
        case .strict:
            return ["--disable-gpu", "--disable-gpu-compositing"]
        case .swiftShader:
            return [
                "--disable-gpu",
                "--use-gl=angle",
                "--use-angle=swiftshader",
                "--enable-unsafe-swiftshader"
            ]
        }
    }

    public var flagsDisplay: String {
        flags.joined(separator: " ")
    }
}

public enum ConfigPatchKind: Equatable, Sendable {
    case chromiumBrowser(bundleID: String, localStateRelativePath: String?)
    case discord(settingsRelativePath: String)
    case vsCodeFamily(argvRelativePath: String)
    case slack(settingsRelativePath: String)
    case spotify(prefsRelativePath: String)

    public var methodName: String {
        switch self {
        case .chromiumBrowser:
            return "macOS Defaults + Chromium Local State"
        case .discord:
            return "Discord settings.json"
        case .vsCodeFamily:
            return "argv.json (JSONC)"
        case .slack:
            return "Slack local-settings.json"
        case .spotify:
            return "Spotify prefs"
        }
    }

    public func targetDescription(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        switch self {
        case .chromiumBrowser(let bundleID, let relPath):
            if let relPath {
                return "defaults (\(bundleID)) & ~/Library/Application Support/\(relPath)"
            }
            return "defaults (\(bundleID)) — HardwareAccelerationModeEnabled"
        case .discord(let relPath):
            return "~/Library/Application Support/\(relPath)"
        case .vsCodeFamily(let relPath):
            return "~/\(relPath)"
        case .slack(let relPath):
            return "~/Library/Application Support/\(relPath)"
        case .spotify(let relPath):
            return "~/Library/Application Support/\(relPath)"
        }
    }
}

public enum ConfigPatchStatus: Equatable, Sendable {
    case unsupported
    case notPatched(ConfigPatchKind)
    case patched(ConfigPatchKind)

    public var isSupported: Bool {
        if case .unsupported = self { return false }
        return true
    }

    public var isPatched: Bool {
        if case .patched = self { return true }
        return false
    }

    public var kind: ConfigPatchKind? {
        switch self {
        case .unsupported: return nil
        case .notPatched(let kind), .patched(let kind): return kind
        }
    }
}

public enum WrapperStatus: Equatable, Sendable {
    case notCreated
    case ready(url: URL, preset: GPUPreset?)

    public var exists: Bool {
        if case .ready = self { return true }
        return false
    }

    public var url: URL? {
        if case .ready(let url, _) = self { return url }
        return nil
    }

    public var preset: GPUPreset? {
        if case .ready(_, let preset) = self { return preset }
        return nil
    }
}

public struct DiscoveredApp: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let bundleIdentifier: String
    public let bundleURL: URL
    public let executableName: String
    public let engine: AppEngine
    public let isManuallyAdded: Bool

    public init(
        name: String,
        bundleIdentifier: String,
        bundleURL: URL,
        executableName: String,
        engine: AppEngine,
        isManuallyAdded: Bool
    ) {
        self.id = bundleURL.standardizedFileURL.path
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL.standardizedFileURL
        self.executableName = executableName
        self.engine = engine
        self.isManuallyAdded = isManuallyAdded
    }
}

public struct ManagedAppState: Equatable, Identifiable, Sendable {
    public var id: String { app.id }
    public let app: DiscoveredApp
    public var selectedPreset: GPUPreset
    public var configStatus: ConfigPatchStatus
    public var wrapperStatus: WrapperStatus
    public var isRunning: Bool

    public init(
        app: DiscoveredApp,
        selectedPreset: GPUPreset,
        configStatus: ConfigPatchStatus,
        wrapperStatus: WrapperStatus,
        isRunning: Bool
    ) {
        self.app = app
        self.selectedPreset = selectedPreset
        self.configStatus = configStatus
        self.wrapperStatus = wrapperStatus
        self.isRunning = isRunning
    }

    public var isProtected: Bool {
        configStatus.isPatched || wrapperStatus.exists
    }

    public var isWrapperPresetOutdated: Bool {
        guard case .ready(_, let wrapperPreset) = wrapperStatus, let wrapperPreset else {
            return false
        }
        return wrapperPreset != selectedPreset
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var wrapperDirectoryPath: String
    public var manualAppPaths: [String]
    public var presetByAppPath: [String: GPUPreset]

    public static func defaultWrapperDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("SafeLaunch", isDirectory: true)
    }

    public static func `default`(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AppSettings {
        AppSettings(
            wrapperDirectoryPath: defaultWrapperDirectory(homeDirectory: homeDirectory).path,
            manualAppPaths: [],
            presetByAppPath: [:]
        )
    }

    public init(
        wrapperDirectoryPath: String,
        manualAppPaths: [String] = [],
        presetByAppPath: [String: GPUPreset] = [:]
    ) {
        self.wrapperDirectoryPath = wrapperDirectoryPath
        self.manualAppPaths = manualAppPaths
        self.presetByAppPath = presetByAppPath
    }

    public var wrapperDirectoryURL: URL {
        URL(fileURLWithPath: (wrapperDirectoryPath as NSString).expandingTildeInPath, isDirectory: true)
    }
}
