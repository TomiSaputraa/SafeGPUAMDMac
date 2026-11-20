import Foundation

public enum WrapperGeneratorError: LocalizedError {
    case failedToCreateBundle(String)
    case failedToWriteScript(String)

    public var errorDescription: String? {
        switch self {
        case .failedToCreateBundle(let detail):
            return "Could not create Wrapper .app bundle: \(detail)"
        case .failedToWriteScript(let detail):
            return "Could not write wrapper launcher script: \(detail)"
        }
    }
}

public struct WrapperGenerator: Sendable {
    public static let targetPathPlistKey = "SafeGPUTargetPath"
    public static let targetBundleIDPlistKey = "SafeGPUTargetBundleID"
    public static let presetPlistKey = "SafeGPUPreset"

    private let iconBadger: IconBadger

    public init(iconBadger: IconBadger = IconBadger()) {
        self.iconBadger = iconBadger
    }

    public func wrapperName(for app: DiscoveredApp) -> String {
        let sanitized = app.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = sanitized.isEmpty ? "App" : sanitized
        return "\(base) (Safe).app"
    }

    public func expectedWrapperURL(for app: DiscoveredApp, in directory: URL) -> URL {
        directory.appendingPathComponent(wrapperName(for: app), isDirectory: true)
    }

    public func wrapperStatus(for app: DiscoveredApp, in directory: URL) -> WrapperStatus {
        let fm = FileManager.default
        let expected = expectedWrapperURL(for: app, in: directory)
        if let info = readWrapperMetadata(at: expected) {
            return .ready(url: expected, preset: info.preset)
        }

        // Fallback scan in case app was renamed slightly
        guard let items = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return .notCreated
        }

        for item in items where item.pathExtension.lowercased() == "app" {
            guard let info = readWrapperMetadata(at: item) else { continue }
            if info.targetPath == app.bundleURL.path || info.targetBundleID == app.bundleIdentifier {
                return .ready(url: item, preset: info.preset)
            }
        }

        return .notCreated
    }

    @discardableResult
    public func generateWrapper(
        for app: DiscoveredApp,
        preset: GPUPreset,
        in directory: URL,
        generateIcon: Bool = true,
        codesign: Bool = true
    ) throws -> URL {
        let fm = FileManager.default
        let wrapperURL = expectedWrapperURL(for: app, in: directory)
        let contentsURL = wrapperURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)

        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: wrapperURL.path) {
                try fm.removeItem(at: wrapperURL)
            }
            try fm.createDirectory(at: macOSURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        } catch {
            throw WrapperGeneratorError.failedToCreateBundle(error.localizedDescription)
        }

        // 1. Write Info.plist
        let displayTitle = wrapperURL.deletingPathExtension().lastPathComponent
        let safeBundleSuffix = app.bundleIdentifier
            .lowercased()
            .map { ch -> Character in
                if ch.isLetter || ch.isNumber || ch == "." || ch == "-" {
                    return ch
                }
                return "-"
            }
        let wrapperBundleID = "com.safegpu.wrapper.\(String(safeBundleSuffix))"

        let plistDict: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleDisplayName": displayTitle,
            "CFBundleExecutable": "launcher",
            "CFBundleIconFile": "AppIcon",
            "CFBundleIdentifier": wrapperBundleID,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": displayTitle,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSUIElement": true,
            AppDetector.wrapperInfoPlistKey: true,
            Self.targetPathPlistKey: app.bundleURL.path,
            Self.targetBundleIDPlistKey: app.bundleIdentifier,
            Self.presetPlistKey: preset.rawValue
        ]

        do {
            let plistData = try PropertyListSerialization.data(
                fromPropertyList: plistDict,
                format: .xml,
                options: 0
            )
            try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"), options: .atomic)
        } catch {
            throw WrapperGeneratorError.failedToCreateBundle(error.localizedDescription)
        }

        // 2. Write executable launcher script
        let scriptURL = macOSURL.appendingPathComponent("launcher")
        let scriptContent = Self.buildLauncherScript(for: app, preset: preset)
        do {
            try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            throw WrapperGeneratorError.failedToWriteScript(error.localizedDescription)
        }

        // 3. Generate badged .icns icon
        if generateIcon {
            let iconURL = resourcesURL.appendingPathComponent("AppIcon.icns")
            try? iconBadger.generateBadgedIcon(forAppAt: app.bundleURL, outputICNSURL: iconURL)
        }

        // 4. Ad-hoc sign and refresh LaunchServices / icon timestamp
        if codesign {
            Self.adHocCodesign(at: wrapperURL)
        }
        Self.touchAndRegister(wrapperURL)

        return wrapperURL
    }

    public func deleteWrapper(for app: DiscoveredApp, in directory: URL) throws {
        guard case .ready(let url, _) = wrapperStatus(for: app, in: directory) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Script Generation & Metadata

    public static func buildLauncherScript(for app: DiscoveredApp, preset: GPUPreset) -> String {
        let quotedTarget = shellQuote(app.bundleURL.path)
        let quotedFlags = preset.flags.map(shellQuote).joined(separator: " ")

        let openEnvSegment: String
        if app.engine == .qtWebEngine {
            let envValue = "QTWEBENGINE_CHROMIUM_FLAGS=\(preset.flags.joined(separator: " "))"
            openEnvSegment = "--env \(shellQuote(envValue)) "
        } else {
            openEnvSegment = ""
        }

        return """
        #!/bin/sh
        # Generated by SafeGPU — Preset: \(preset.displayName)
        TARGET_APP=\(quotedTarget)

        if [ ! -d "$TARGET_APP" ]; then
          /usr/bin/osascript -e 'display alert "Target App Not Found" message "SafeGPU could not find the original application. Please regenerate this wrapper in SafeGPU." as warning' >/dev/null 2>&1
          exit 1
        fi

        # Filter out macOS LaunchServices -psn_ arguments while preserving argument quoting
        count=$#
        i=0
        while [ "$i" -lt "$count" ]; do
          arg=$1
          shift
          case "$arg" in
            -psn_*) ;;
            *) set -- "$@" "$arg" ;;
          esac
          i=$((i + 1))
        done

        exec /usr/bin/open \(openEnvSegment)-a "$TARGET_APP" --args \(quotedFlags) "$@"
        """
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private struct WrapperMetadata {
        let targetPath: String
        let targetBundleID: String
        let preset: GPUPreset?
    }

    private func readWrapperMetadata(at wrapperURL: URL) -> WrapperMetadata? {
        let plistURL = wrapperURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")

        guard
            let data = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            (plist[AppDetector.wrapperInfoPlistKey] as? Bool) == true
        else {
            return nil
        }

        let targetPath = (plist[Self.targetPathPlistKey] as? String) ?? ""
        let targetBundleID = (plist[Self.targetBundleIDPlistKey] as? String) ?? ""
        let presetRaw = plist[Self.presetPlistKey] as? String
        let preset = presetRaw.flatMap(GPUPreset.init(rawValue:))

        return WrapperMetadata(
            targetPath: targetPath,
            targetBundleID: targetBundleID,
            preset: preset
        )
    }

    private static func adHocCodesign(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", url.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    private static func touchAndRegister(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )

        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        if FileManager.default.isExecutableFile(atPath: lsregister) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: lsregister)
            process.arguments = ["-f", url.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
        }
    }
}
