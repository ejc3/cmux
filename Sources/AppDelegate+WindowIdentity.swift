import AppKit
import Foundation

extension NSWindow {
    /// Whether the user can still reach this window: it is on screen, or it is
    /// minimized in the Dock and one click from coming back.
    ///
    /// `isVisible` alone is the wrong check. A miniaturized window
    /// reports `isVisible == false` yet is still open, so filtering on
    /// visibility would hide minimized windows from the switcher. And a window
    /// that was `orderOut(_:)`'d stays in `NSApp.windows` for as long as anything
    /// still references it, so looking it up by identity keeps finding it long
    /// after it closed. That is how a closed window gets listed and focused.
    var isReachableByUser: Bool {
        isVisible || isMiniaturized
    }
}

@MainActor
extension AppDelegate {
    func mainWindow(for windowId: UUID) -> NSWindow? {
        windowForMainWindowId(windowId)
    }

    func windowForMainWindowId(_ windowId: UUID) -> NSWindow? {
        if let ctx = mainWindowContexts.values.first(where: { $0.windowId == windowId }),
           let window = ctx.window {
            return window
        }
        let expectedIdentifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == expectedIdentifier })
    }

    func startupPrimaryWindowIdForInitialMainWindow() -> UUID? {
        guard !didAttemptStartupSessionRestore else { return nil }
        guard !didHandleExplicitOpenIntentAtStartup else { return nil }
        return startupSessionSnapshot?.windows.first?.windowId
    }

    func availableWindowIdForNewMainWindow(preferredWindowId: UUID?) -> UUID? {
        guard let preferredWindowId else { return nil }
        guard !mainWindowContexts.values.contains(where: { $0.windowId == preferredWindowId }) else { return nil }
        return preferredWindowId
    }

    func refreshWindowTitlesAcrossMainWindows() {
        var seenManagers = Set<ObjectIdentifier>()
        for context in mainWindowContexts.values {
            let identifier = ObjectIdentifier(context.tabManager)
            guard seenManagers.insert(identifier).inserted else { continue }
            context.tabManager.refreshWindowTitle()
        }
    }
}
