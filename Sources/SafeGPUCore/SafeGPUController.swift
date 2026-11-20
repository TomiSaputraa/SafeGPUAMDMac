import AppKit
import Foundation

@MainActor
public final class SafeGPUController {
    public private(set) var settings: AppSettings
    public private(set) var apps: [ManagedAppState] = []

    public let detector: AppDetector
    public let configPatcher: ConfigPatcher
    public let wrapperGenerator: WrapperGenerator
    public let launcher: SafeLauncher
    public let settingsStore: SettingsStore

    public var onStateChanged: (() -> Void)?

    public init(
        detector: AppDetector = AppDetector(),
        configPatcher: ConfigPatcher = ConfigPatcher(),
        wrapperGenerator: WrapperGenerator = WrapperGenerator(),
        launcher: SafeLauncher = SafeLauncher(),
        settingsStore: SettingsStore = SettingsStore()
    ) {
        self.detector = detector
        self.configPatcher = configPatcher
        self.wrapperGenerator = wrapperGenerator
        self.launcher = launcher
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()
    }

    public func rescan() {
        let discovered = detector.scanApplications(manualAppPaths: settings.manualAppPaths)
        let wrapperDir = settings.wrapperDirectoryURL

        self.apps = discovered.map { app in
            let preset = settings.presetByAppPath[app.id] ?? .standard
            let configStatus = configPatcher.status(for: app)
            let wrapperStatus = wrapperGenerator.wrapperStatus(for: app, in: wrapperDir)
            let running = launcher.isRunning(app)
            return ManagedAppState(
                app: app,
                selectedPreset: preset,
                configStatus: configStatus,
                wrapperStatus: wrapperStatus,
                isRunning: running
            )
        }

        onStateChanged?()
    }

    public func refreshApp(id: String) {
        guard let idx = apps.firstIndex(where: { $0.id == id }) else {
            rescan()
            return
        }
        let app = apps[idx].app
        let preset = settings.presetByAppPath[app.id] ?? .standard
        apps[idx] = ManagedAppState(
            app: app,
            selectedPreset: preset,
            configStatus: configPatcher.status(for: app),
            wrapperStatus: wrapperGenerator.wrapperStatus(for: app, in: settings.wrapperDirectoryURL),
            isRunning: launcher.isRunning(app)
        )
        onStateChanged?()
    }

    @discardableResult
    public func addManualApp(at url: URL) throws -> DiscoveredApp? {
        let standardized = url.standardizedFileURL
        guard standardized.pathExtension.lowercased() == "app" else { return nil }
        guard let inspected = detector.inspectApp(at: standardized, isManuallyAdded: true) else {
            return nil
        }

        if !settings.manualAppPaths.contains(inspected.id) {
            settings.manualAppPaths.append(inspected.id)
            try settingsStore.save(settings)
        }
        rescan()
        return apps.first(where: { $0.id == inspected.id })?.app ?? inspected
    }

    public func removeManualApp(_ app: DiscoveredApp) throws {
        settings.manualAppPaths.removeAll { $0 == app.id }
        try settingsStore.save(settings)
        rescan()
    }

    public func setPreset(_ preset: GPUPreset, for app: DiscoveredApp) throws {
        settings.presetByAppPath[app.id] = preset
        try settingsStore.save(settings)
        refreshApp(id: app.id)
    }

    public func applyConfigPatch(for app: DiscoveredApp) throws {
        try configPatcher.applyPatch(for: app)
        refreshApp(id: app.id)
    }

    public func revertConfigPatch(for app: DiscoveredApp) throws {
        try configPatcher.revertPatch(for: app)
        refreshApp(id: app.id)
    }

    @discardableResult
    public func createOrUpdateWrapper(for app: DiscoveredApp) throws -> URL {
        let preset = settings.presetByAppPath[app.id] ?? .standard
        let url = try wrapperGenerator.generateWrapper(
            for: app,
            preset: preset,
            in: settings.wrapperDirectoryURL
        )
        refreshApp(id: app.id)
        return url
    }

    public func deleteWrapper(for app: DiscoveredApp) throws {
        try wrapperGenerator.deleteWrapper(for: app, in: settings.wrapperDirectoryURL)
        refreshApp(id: app.id)
    }

    public func launchSafe(_ app: DiscoveredApp) throws {
        let preset = settings.presetByAppPath[app.id] ?? .standard
        try launcher.launchSafe(app, preset: preset)
        // Update running status shortly after launch
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            self?.refreshApp(id: app.id)
        }
    }

    public func terminate(_ app: DiscoveredApp) async -> Bool {
        let terminated = await launcher.terminate(app)
        refreshApp(id: app.id)
        return terminated
    }

    public func updateWrapperDirectory(_ url: URL) throws {
        settings.wrapperDirectoryPath = url.standardizedFileURL.path
        try settingsStore.save(settings)
        rescan()
    }

    public func resetWrapperDirectory() throws {
        settings.wrapperDirectoryPath = AppSettings.defaultWrapperDirectory().path
        try settingsStore.save(settings)
        rescan()
    }
}
