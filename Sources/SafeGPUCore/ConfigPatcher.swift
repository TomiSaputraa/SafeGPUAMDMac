import Foundation

public protocol DefaultsAccessing: Sendable {
    func readBool(domain: String, key: String) -> Bool?
    func writeBool(domain: String, key: String, value: Bool) throws
    func deleteKey(domain: String, key: String) throws
}

public enum ConfigPatchError: LocalizedError {
    case unsupportedApp(String)
    case invalidJSON(URL, String)
    case defaultsCommandFailed(String)
    case ioFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedApp(let name):
            return "\(name) does not support automatic config patching."
        case .invalidJSON(let url, let detail):
            return "Could not parse config file at \(url.path): \(detail)"
        case .defaultsCommandFailed(let message):
            return "macOS defaults command failed: \(message)"
        case .ioFailed(let message):
            return "File operation failed: \(message)"
        }
    }
}

public struct SystemDefaultsAccess: DefaultsAccessing {
    public init() {}

    public func readBool(domain: String, key: String) -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", domain, key]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else {
            return nil
        }

        switch output {
        case "1", "true", "yes":
            return true
        case "0", "false", "no":
            return false
        default:
            return nil
        }
    }

    public func writeBool(domain: String, key: String, value: Bool) throws {
        try runDefaults(arguments: ["write", domain, key, "-bool", value ? "true" : "false"])
    }

    public func deleteKey(domain: String, key: String) throws {
        // Ignore error when key does not exist
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["delete", domain, key]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
    }

    private func runDefaults(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments

        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Exit code \(process.terminationStatus)"
            throw ConfigPatchError.defaultsCommandFailed(errText)
        }
    }
}

public struct ConfigPatcher: Sendable {
    private static let chromiumDefaultsKey = "HardwareAccelerationModeEnabled"

    private static let chromiumLocalStatePaths: [String: String] = [
        "com.google.Chrome": "Google/Chrome/Local State",
        "com.google.Chrome.beta": "Google/Chrome Beta/Local State",
        "com.google.Chrome.canary": "Google/Chrome Canary/Local State",
        "com.google.Chrome.dev": "Google/Chrome Dev/Local State",
        "com.brave.Browser": "BraveSoftware/Brave-Browser/Local State",
        "com.brave.Browser.beta": "BraveSoftware/Brave-Browser-Beta/Local State",
        "com.brave.Browser.nightly": "BraveSoftware/Brave-Browser-Nightly/Local State",
        "com.microsoft.edgemac": "Microsoft Edge/Local State",
        "com.microsoft.edgemac.Beta": "Microsoft Edge Beta/Local State",
        "com.microsoft.edgemac.Dev": "Microsoft Edge Dev/Local State",
        "com.microsoft.edgemac.Canary": "Microsoft Edge Canary/Local State",
        "com.vivaldi.Vivaldi": "Vivaldi/Local State",
        "com.vivaldi.Vivaldi.snapshot": "Vivaldi Snapshot/Local State",
        "com.operasoftware.Opera": "com.operasoftware.Opera/Local State",
        "com.operasoftware.OperaGX": "com.operasoftware.OperaGX/Local State",
        "org.chromium.Chromium": "Chromium/Local State",
        "company.thebrowser.Browser": "Arc/User Data/Local State"
    ]

    private static let discordSettingsPaths: [String: String] = [
        "com.hnc.Discord": "discord/settings.json",
        "com.hnc.DiscordPTB": "discordptb/settings.json",
        "com.hnc.DiscordCanary": "discordcanary/settings.json"
    ]

    private static let vsCodeArgvPaths: [String: String] = [
        "com.microsoft.VSCode": ".vscode/argv.json",
        "com.microsoft.VSCodeInsiders": ".vscode-insiders/argv.json",
        "com.vscodium": ".vscode-oss/argv.json",
        "com.visualstudio.code.oss": ".vscode-oss/argv.json",
        "com.todesktop.230313mzl4w4u92": ".cursor/argv.json",
        "com.exafunction.windsurf": ".windsurf/argv.json",
        "com.google.antigravity": ".antigravity/argv.json"
    ]

    public let homeDirectory: URL
    public let defaults: any DefaultsAccessing

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        defaults: any DefaultsAccessing = SystemDefaultsAccess()
    ) {
        self.homeDirectory = homeDirectory
        self.defaults = defaults
    }

    public func patchKind(for app: DiscoveredApp) -> ConfigPatchKind? {
        let id = app.bundleIdentifier

        if let localState = Self.chromiumLocalStatePaths[id] {
            return .chromiumBrowser(bundleID: id, localStateRelativePath: localState)
        }
        if let discordPath = Self.discordSettingsPaths[id] {
            return .discord(settingsRelativePath: discordPath)
        }
        if let argvPath = Self.vsCodeArgvPaths[id] {
            return .vsCodeFamily(argvRelativePath: argvPath)
        }
        if id == "com.tinyspeck.slackmacgap" {
            return .slack(settingsRelativePath: "Slack/local-settings.json")
        }
        if id == "com.spotify.client" {
            return .spotify(prefsRelativePath: "Spotify/prefs")
        }
        if app.engine == .chromium && !id.hasPrefix("unknown.") {
            return .chromiumBrowser(bundleID: id, localStateRelativePath: nil)
        }
        return nil
    }

    public func status(for app: DiscoveredApp) -> ConfigPatchStatus {
        guard let kind = patchKind(for: app) else {
            return .unsupported
        }
        return isPatched(kind: kind) ? .patched(kind) : .notPatched(kind)
    }

    public func applyPatch(for app: DiscoveredApp) throws {
        guard let kind = patchKind(for: app) else {
            throw ConfigPatchError.unsupportedApp(app.name)
        }

        switch kind {
        case .chromiumBrowser(let bundleID, let localStateRelPath):
            try defaults.writeBool(domain: bundleID, key: Self.chromiumDefaultsKey, value: false)
            if let localStateRelPath {
                let url = appSupportURL(relativePath: localStateRelPath)
                if FileManager.default.fileExists(atPath: url.path) {
                    var json = try readJSONObject(at: url, allowJSONC: false)
                    var hwMode = (json["hardware_acceleration_mode"] as? [String: Any]) ?? [:]
                    hwMode["enabled"] = false
                    json["hardware_acceleration_mode"] = hwMode
                    try writeJSONObject(json, to: url)
                }
            }

        case .discord(let relPath):
            let url = appSupportURL(relativePath: relPath)
            var json = FileManager.default.fileExists(atPath: url.path)
                ? try readJSONObject(at: url, allowJSONC: false)
                : [:]
            json["enableHardwareAcceleration"] = false
            try writeJSONObject(json, to: url)

        case .vsCodeFamily(let relPath):
            let url = homeDirectory.appendingPathComponent(relPath)
            var json = FileManager.default.fileExists(atPath: url.path)
                ? try readJSONObject(at: url, allowJSONC: true)
                : [:]
            json["disable-hardware-acceleration"] = true
            try writeJSONObject(json, to: url)

        case .slack(let relPath):
            let url = appSupportURL(relativePath: relPath)
            var json = FileManager.default.fileExists(atPath: url.path)
                ? try readJSONObject(at: url, allowJSONC: false)
                : [:]
            json["useHwAcceleration"] = false
            try writeJSONObject(json, to: url)

        case .spotify(let relPath):
            let url = appSupportURL(relativePath: relPath)
            try setSpotifyPref(at: url, key: "ui.hardware_acceleration", value: "false")
        }
    }

    public func revertPatch(for app: DiscoveredApp) throws {
        guard let kind = patchKind(for: app) else {
            throw ConfigPatchError.unsupportedApp(app.name)
        }

        switch kind {
        case .chromiumBrowser(let bundleID, let localStateRelPath):
            try defaults.deleteKey(domain: bundleID, key: Self.chromiumDefaultsKey)
            if let localStateRelPath {
                let url = appSupportURL(relativePath: localStateRelPath)
                if FileManager.default.fileExists(atPath: url.path) {
                    var json = try readJSONObject(at: url, allowJSONC: false)
                    if var hwMode = json["hardware_acceleration_mode"] as? [String: Any] {
                        hwMode["enabled"] = true
                        json["hardware_acceleration_mode"] = hwMode
                        try writeJSONObject(json, to: url)
                    }
                }
            }

        case .discord(let relPath):
            let url = appSupportURL(relativePath: relPath)
            if FileManager.default.fileExists(atPath: url.path) {
                var json = try readJSONObject(at: url, allowJSONC: false)
                json["enableHardwareAcceleration"] = true
                try writeJSONObject(json, to: url)
            }

        case .vsCodeFamily(let relPath):
            let url = homeDirectory.appendingPathComponent(relPath)
            if FileManager.default.fileExists(atPath: url.path) {
                var json = try readJSONObject(at: url, allowJSONC: true)
                json.removeValue(forKey: "disable-hardware-acceleration")
                try writeJSONObject(json, to: url)
            }

        case .slack(let relPath):
            let url = appSupportURL(relativePath: relPath)
            if FileManager.default.fileExists(atPath: url.path) {
                var json = try readJSONObject(at: url, allowJSONC: false)
                json["useHwAcceleration"] = true
                try writeJSONObject(json, to: url)
            }

        case .spotify(let relPath):
            let url = appSupportURL(relativePath: relPath)
            if FileManager.default.fileExists(atPath: url.path) {
                try setSpotifyPref(at: url, key: "ui.hardware_acceleration", value: "true")
            }
        }
    }

    // MARK: - Inspection Helpers

    private func isPatched(kind: ConfigPatchKind) -> Bool {
        switch kind {
        case .chromiumBrowser(let bundleID, let localStateRelPath):
            let defaultsDisabled = defaults.readBool(domain: bundleID, key: Self.chromiumDefaultsKey) == false
            if let localStateRelPath {
                let url = appSupportURL(relativePath: localStateRelPath)
                if FileManager.default.fileExists(atPath: url.path) {
                    let localStateDisabled = readLocalStateDisabled(at: url)
                    return defaultsDisabled && localStateDisabled
                }
            }
            return defaultsDisabled

        case .discord(let relPath):
            let url = appSupportURL(relativePath: relPath)
            guard let json = try? readJSONObject(at: url, allowJSONC: false) else { return false }
            return (json["enableHardwareAcceleration"] as? Bool) == false

        case .vsCodeFamily(let relPath):
            let url = homeDirectory.appendingPathComponent(relPath)
            guard let json = try? readJSONObject(at: url, allowJSONC: true) else { return false }
            return (json["disable-hardware-acceleration"] as? Bool) == true

        case .slack(let relPath):
            let url = appSupportURL(relativePath: relPath)
            guard let json = try? readJSONObject(at: url, allowJSONC: false) else { return false }
            return (json["useHwAcceleration"] as? Bool) == false

        case .spotify(let relPath):
            let url = appSupportURL(relativePath: relPath)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return false }
            for rawLine in content.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("ui.hardware_acceleration=") {
                    let val = line.dropFirst("ui.hardware_acceleration=".count)
                        .trimmingCharacters(in: .whitespaces)
                        .lowercased()
                    return val == "false"
                }
            }
            return false
        }
    }

    private func readLocalStateDisabled(at url: URL) -> Bool {
        guard let json = try? readJSONObject(at: url, allowJSONC: false),
              let hwMode = json["hardware_acceleration_mode"] as? [String: Any],
              let enabled = hwMode["enabled"] as? Bool
        else {
            return false
        }
        return enabled == false
    }

    private func appSupportURL(relativePath: String) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(relativePath)
    }

    // MARK: - JSON / JSONC & Prefs I/O

    private func readJSONObject(at url: URL, allowJSONC: Bool) throws -> [String: Any] {
        let rawText: String
        do {
            rawText = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ConfigPatchError.ioFailed(error.localizedDescription)
        }

        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return [:]
        }

        let cleanText = allowJSONC ? Self.stripJSONC(trimmed) : trimmed
        guard let data = cleanText.data(using: .utf8) else {
            throw ConfigPatchError.invalidJSON(url, "UTF-8 conversion failed")
        }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ConfigPatchError.invalidJSON(url, error.localizedDescription)
        }

        guard let dict = parsed as? [String: Any] else {
            throw ConfigPatchError.invalidJSON(url, "Top-level JSON value is not an object")
        }
        return dict
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            var out = data
            out.append(0x0A) // trailing newline
            try out.write(to: url, options: .atomic)
        } catch {
            throw ConfigPatchError.ioFailed(error.localizedDescription)
        }
    }

    private func setSpotifyPref(at url: URL, key: String, value: String) throws {
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            var lines = existing.isEmpty ? [] : existing.components(separatedBy: .newlines)
            // Remove trailing empty element produced by trailing newline
            if lines.last == "" {
                lines.removeLast()
            }

            var updated = false
            for idx in lines.indices {
                if lines[idx].trimmingCharacters(in: .whitespaces).hasPrefix("\(key)=") {
                    lines[idx] = "\(key)=\(value)"
                    updated = true
                }
            }
            if !updated {
                lines.append("\(key)=\(value)")
            }

            let finalText = lines.joined(separator: "\n") + "\n"
            try finalText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ConfigPatchError.ioFailed(error.localizedDescription)
        }
    }

    /// Strips `//` line comments, `/* ... */` block comments, and trailing commas outside string literals.
    public static func stripJSONC(_ input: String) -> String {
        let chars = Array(input)
        let count = chars.count
        var noComments: [Character] = []
        noComments.reserveCapacity(count)

        var i = 0
        var inString = false
        var escaped = false

        while i < count {
            let c = chars[i]

            if inString {
                noComments.append(c)
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                i += 1
                continue
            }

            if c == "\"" {
                inString = true
                noComments.append(c)
                i += 1
                continue
            }

            if c == "/" && i + 1 < count {
                let next = chars[i + 1]
                if next == "/" {
                    i += 2
                    while i < count && chars[i] != "\n" && chars[i] != "\r" {
                        i += 1
                    }
                    continue
                } else if next == "*" {
                    i += 2
                    while i + 1 < count && !(chars[i] == "*" && chars[i + 1] == "/") {
                        i += 1
                    }
                    i = min(count, i + 2)
                    continue
                }
            }

            noComments.append(c)
            i += 1
        }

        // Second pass: strip trailing commas before `}` or `]` outside strings
        var result: [Character] = []
        result.reserveCapacity(noComments.count)
        let n = noComments.count
        var j = 0
        inString = false
        escaped = false

        while j < n {
            let c = noComments[j]
            if inString {
                result.append(c)
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                j += 1
                continue
            }

            if c == "\"" {
                inString = true
                result.append(c)
                j += 1
                continue
            }

            if c == "," {
                var lookahead = j + 1
                while lookahead < n && (noComments[lookahead] == " " || noComments[lookahead] == "\t" || noComments[lookahead] == "\n" || noComments[lookahead] == "\r") {
                    lookahead += 1
                }
                if lookahead < n && (noComments[lookahead] == "}" || noComments[lookahead] == "]") {
                    // Drop trailing comma
                    j += 1
                    continue
                }
            }

            result.append(c)
            j += 1
        }

        return String(result)
    }
}
