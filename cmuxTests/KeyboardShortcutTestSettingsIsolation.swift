import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
extension KeyboardShortcutSettings {
    static func installIsolatedTestFileStore(prefix: String) -> KeyboardShortcutSettingsFileStore {
        let original = settingsFileStore
        let settingsFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).json", isDirectory: false)
        settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false,
            // An isolated store reads its own temp file; it has no business reverting the host's
            // managed settings or deleting the bookkeeping that would restore them. Twelve suites
            // reach this helper, so opting out here is what keeps them from mutating the real
            // defaults domain that other suites read.
            applyManagedSettings: false
        )
        return original
    }
}
