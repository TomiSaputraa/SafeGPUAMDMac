import Foundation

public struct SettingsStore: Sendable {
    public let fileURL: URL
    public let homeDirectory: URL

    public init(
        fileURL: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.homeDirectory = homeDirectory
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("SafeGPU", isDirectory: true)
                .appendingPathComponent("settings.json")
        }
    }

    public func load() -> AppSettings {
        guard
            let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return .default(homeDirectory: homeDirectory)
        }

        var normalized = decoded
        if normalized.wrapperDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.wrapperDirectoryPath = AppSettings.defaultWrapperDirectory(homeDirectory: homeDirectory).path
        }
        return normalized
    }

    public func save(_ settings: AppSettings) throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(settings)
        data.append(0x0A)
        try data.write(to: fileURL, options: .atomic)
    }
}
