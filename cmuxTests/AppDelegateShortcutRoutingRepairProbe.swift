import AppKit
import CmuxTerminal
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AppDelegateShortcutRoutingTests {
    func focusHostedTerminalForRepairTesting(
        window: NSWindow,
        hostedView: GhosttySurfaceScrollView
    ) {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        hostedView.moveFocus()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertTrue(
            hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to own first responder before repair test"
        )
    }

    func installStrandedResponderDriftForTesting(
        _ responder: NSView,
        in window: NSWindow,
        hostedView: GhosttySurfaceScrollView
    ) {
        (window.contentView?.superview ?? window.contentView)?.addSubview(responder)
        XCTAssertTrue(window.makeFirstResponder(responder), "Expected test to install a stranded responder")
        XCTAssertTrue(window.firstResponder === responder, "Expected real first responder drift before removal")
        responder.removeFromSuperview()
        XCTAssertNil(responder.window, "Expected a simulated stranded responder")
        XCTAssertFalse(
            hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to lose first responder before repaired typing"
        )
    }

    func installVisibleResponderDriftForTesting(
        _ responder: NSView,
        in window: NSWindow,
        hostedView: GhosttySurfaceScrollView,
        mismatchMessage: String
    ) {
        (window.contentView?.superview ?? window.contentView)?.addSubview(responder)
        XCTAssertTrue(responder.window === window, "Expected a simulated same-window responder")
        XCTAssertTrue(window.makeFirstResponder(responder), "Expected test to install a visible wrong first responder")
        XCTAssertTrue(window.firstResponder === responder, "Expected real same-window responder drift before repair")
        XCTAssertFalse(hostedView.responderMatchesPreferredKeyboardFocus(responder), mismatchMessage)
        XCTAssertFalse(
            hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to lose first responder before repaired typing"
        )
    }

    func installSearchResponderDriftForTesting(
        _ responder: NSView,
        in window: NSWindow,
        hostedView: GhosttySurfaceScrollView,
        searchField: NSTextField
    ) {
        (window.contentView?.superview ?? window.contentView)?.addSubview(responder)
        XCTAssertTrue(responder.window === window, "Expected a simulated same-window responder")
        XCTAssertTrue(window.makeFirstResponder(responder), "Expected test to install a visible wrong first responder")
        XCTAssertTrue(window.firstResponder === responder, "Expected real same-window responder drift before repair")
        XCTAssertFalse(
            hostedView.responderMatchesPreferredKeyboardFocus(responder),
            "Expected the simulated responder to disagree with terminal search focus"
        )
        XCTAssertFalse(
            repairProbeFirstResponderOwnsTextField(window.firstResponder, textField: searchField),
            "Expected terminal search field to lose first responder before repaired typing"
        )
    }

    func installFocusedTerminalRepairProbeForTesting(
        appDelegate: AppDelegate,
        keyCode: UInt32
    ) -> (
        repairCount: () -> Int,
        repairResponder: () -> NSResponder?,
        forwardedKeyDownCount: () -> Int,
        restore: () -> Void
    ) {
        var repairCount = 0
        var repairResponder: NSResponder?
        let previousRepairObserver = appDelegate.debugFocusedTerminalKeyRepairObserverForTesting
        appDelegate.debugFocusedTerminalKeyRepairObserverForTesting = { window, event, responder in
            previousRepairObserver?(window, event, responder)
            guard UInt32(event.keyCode) == keyCode else { return }
            repairCount += 1
            repairResponder = responder
        }

        var forwardedKeyDownCount = 0
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS, keyEvent.keycode == keyCode else { return }
            forwardedKeyDownCount += 1
        }

        return (
            repairCount: { repairCount },
            repairResponder: { repairResponder },
            forwardedKeyDownCount: { forwardedKeyDownCount },
            restore: {
                appDelegate.debugFocusedTerminalKeyRepairObserverForTesting = previousRepairObserver
                GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
            }
        )
    }

    private func repairProbeFirstResponderOwnsTextField(
        _ firstResponder: NSResponder?,
        textField: NSTextField
    ) -> Bool {
        if firstResponder === textField {
            return true
        }
        if let editor = firstResponder as? NSTextView,
           editor.isFieldEditor,
           editor.delegate as? NSTextField === textField {
            return true
        }
        return false
    }
}

// MARK: - Test-host window leak bisect probe (temporary diagnostic)

/// Bisects the shared test-host window/surface leak. Each level adds one step of
/// what the shortcut-routing suites do, so the first failing level names the
/// step that introduces the retain. Counts, not timings — load-independent.
@MainActor
final class TestHostWindowLeakProbeTests: XCTestCase {
    private func drainMainLoop(_ turns: Int = 30) {
        for _ in 0..<turns {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }

    private func mainWindowCount() -> Int {
        NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("cmux.main.") == true }.count
    }

    // Level 0: the `makeRegisteredShortcutRoutingWindow` shape — a bare
    // programmatic NSWindow with isReleasedWhenClosed = false, closed and
    // dropped. If this leaks, NSApp's window list itself is the owner.
    func testLevel0BareFabricatedWindowDeallocs() {
        weak var weakWindow: NSWindow?
        autoreleasepool {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(UUID().uuidString)")
            weakWindow = window
            window.orderOut(nil)
            window.close()
        }
        drainMainLoop()
        XCTAssertNil(weakWindow, "LEVEL0: bare fabricated cmux.main window leaked")
    }

    // Level 1: same, but ordered in first (this also trips the
    // makeKeyAndOrderFront focus-capture swizzle the suites install).
    func testLevel1OrderedInFabricatedWindowDeallocs() {
        AppDelegate.installWindowResponderSwizzlesForTesting()
        weak var weakWindow: NSWindow?
        autoreleasepool {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(UUID().uuidString)")
            weakWindow = window
            window.makeKeyAndOrderFront(nil)
            window.orderOut(nil)
            window.close()
        }
        drainMainLoop()
        XCTAssertNil(weakWindow, "LEVEL1: ordered-in fabricated cmux.main window leaked")
    }

    // Level 2: the product path — what 116 call sites in
    // AppDelegateShortcutRoutingTests exercise.
    func testLevel2CreateMainWindowDeallocsAfterClose() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }
        let previousConfirmation = appDelegate.debugCloseMainWindowConfirmationHandler
        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }
        defer { appDelegate.debugCloseMainWindowConfirmationHandler = previousConfirmation }

        weak var weakWindow: NSWindow?
        weak var weakContentView: NSView?
        autoreleasepool {
            let windowId = appDelegate.createMainWindow(shouldActivate: false)
            let identifier = "cmux.main.\(windowId.uuidString)"
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == identifier }) else {
                XCTFail("Expected a created main window for \(identifier)")
                return
            }
            weakWindow = window
            weakContentView = window.contentView
            window.animationBehavior = .none
            window.orderOut(nil)
            window.close()
        }
        drainMainLoop()
        XCTAssertNil(weakContentView, "LEVEL2: main window contentView leaked after close")
        XCTAssertNil(weakWindow, "LEVEL2: createMainWindow window leaked after close")
    }

    // Level 3: structural gauge — repeated create/close must not accumulate.
    func testLevel3RepeatedCreateCloseDoesNotAccumulateWindows() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }
        let previousConfirmation = appDelegate.debugCloseMainWindowConfirmationHandler
        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }
        defer { appDelegate.debugCloseMainWindowConfirmationHandler = previousConfirmation }

        let before = mainWindowCount()
        for _ in 0..<5 {
            autoreleasepool {
                let windowId = appDelegate.createMainWindow(shouldActivate: false)
                let identifier = "cmux.main.\(windowId.uuidString)"
                guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == identifier }) else {
                    return
                }
                window.animationBehavior = .none
                window.orderOut(nil)
                window.close()
            }
            drainMainLoop(10)
        }
        drainMainLoop()
        let after = mainWindowCount()
        XCTAssertEqual(
            after,
            before,
            "LEVEL3: cmux.main windows accumulated across 5 create/close cycles (before=\(before) after=\(after))"
        )
    }
}

/// Dumps the live cmux.main window population with the one attribute that
/// decides where the leak lives: the delegate class. A product window from
/// createMainWindow is delegated to a MainWindowController; a nil delegate means
/// either a test-fabricated window or a product window whose controller already
/// went away. Named to sort after AppDelegateShortcutRoutingTests so it observes
/// that suite's residue in the shared host.
@MainActor
final class ZZTestHostLeakStateDumpTests: XCTestCase {
    func testDumpLiveMainWindowPopulation() {
        var byDelegate: [String: Int] = [:]
        var visibleCount = 0
        var releasedWhenClosedCount = 0
        var mainWindows = 0
        for window in NSApp.windows {
            guard window.identifier?.rawValue.hasPrefix("cmux.main.") == true else { continue }
            mainWindows += 1
            let delegateName = window.delegate.map { String(describing: type(of: $0)) } ?? "<nil>"
            byDelegate[delegateName, default: 0] += 1
            if window.isVisible { visibleCount += 1 }
            if window.isReleasedWhenClosed { releasedWhenClosedCount += 1 }
        }
        let allWindows = NSApp.windows.count
        let delegateSummary = byDelegate
            .sorted { $0.value > $1.value }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let snapshot = GhosttyApp.terminalSurfaceRegistry.diagnosticSnapshot()
        print("""
        LEAKDUMP mainWins=\(mainWindows) allWins=\(allWindows) visible=\(visibleCount) \
        releasedWhenClosed=\(releasedWhenClosedCount) delegates[\(delegateSummary)] \
        surfaces=\(snapshot.registeredSurfaceCount) runtime=\(snapshot.runtimeSurfaceCount) \
        workspace=\(snapshot.workspaceSurfaceCount) dock=\(snapshot.rightSidebarDockSurfaceCount)
        """)
    }
}

/// Diagnostic scaffolding (temporary): reproduces the leak, publishes the leaked
/// window addresses plus our pid, then holds the process open so an external
/// `heap`/`leaks --trace` can name the retainer. Inert unless
/// CMUX_LEAKHUNT_PAUSE=1, so it costs a normal run nothing.
@MainActor
final class ZZZLeakhuntPauseHarnessTests: XCTestCase {
    func testPauseForMemoryGraph() {
        guard ProcessInfo.processInfo.environment["CMUX_LEAKHUNT_PAUSE"] == "1" else { return }
        guard let appDelegate = AppDelegate.shared else { return }
        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }

        func drain(_ turns: Int) {
            for _ in 0..<turns { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        }

        for _ in 0..<3 {
            autoreleasepool {
                let windowId = appDelegate.createMainWindow(shouldActivate: false)
                let identifier = "cmux.main.\(windowId.uuidString)"
                guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == identifier }) else {
                    return
                }
                window.animationBehavior = .none
                window.orderOut(nil)
                window.close()
            }
            drain(10)
        }
        drain(30)

        let leaked = NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("cmux.main.") == true }
        let addrs = leaked.map { window -> String in
            let bits = UInt(bitPattern: Unmanaged.passUnretained(window).toOpaque())
            return "0x" + String(bits, radix: 16)
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let payload = (["pid=\(pid)"] + addrs).joined(separator: "\n")
        try? payload.write(toFile: "/tmp/leakhunt-addrs.txt", atomically: true, encoding: .utf8)
        print("LEAKHUNT_PAUSE_READY pid=\(pid) count=\(addrs.count) addrs=\(addrs.joined(separator: ","))")

        let deadline = Date(timeIntervalSinceNow: 600)
        while Date() < deadline, !FileManager.default.fileExists(atPath: "/tmp/leakhunt-release") {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
        }
        print("LEAKHUNT_PAUSE_RELEASED")
    }
}
