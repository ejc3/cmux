import AppKit
import Testing
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Terminal search overlay mouse release")
struct TerminalSearchOverlayMouseReleaseTests {
    @Test("Search overlay forwards terminal mouse release during selection drag")
    func searchOverlayForwardsTerminalMouseReleaseDuringSelectionDrag() async throws {
        let surface = makeTerminalSurface()
        defer { surface.releaseSurfaceForTesting() }

        let (hostedView, window) = try attachToWindow(surface: surface)
        defer { window.orderOut(nil) }

        hostedView.setSearchOverlay(searchState: TerminalSurface.SearchState(needle: "needle"))
        #expect(await waitUntil(description: "search overlay to mount") {
            hostedView.debugHasSearchOverlay()
        })

        let terminalView = try #require(surfaceView(in: hostedView) as? GhosttyNSView)
        let overlay = try #require(hostedView.debugSearchOverlayHostingViewForTesting())

        let downLocation = terminalView.convert(NSPoint(x: 24, y: 24), to: nil)
        terminalView.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: downLocation, window: window))
        #expect(
            hostedView.debugSurfaceHasPendingLeftMouseReleaseForTesting(),
            "Terminal selection should own the left-button release after mouseDown"
        )

        let overlayLocation = overlay.convert(NSPoint(x: overlay.bounds.midX, y: overlay.bounds.midY), to: nil)
        overlay.mouseDragged(with: makeMouseEvent(type: .leftMouseDragged, location: overlayLocation, window: window))
        #expect(
            hostedView.debugSurfaceHasPendingLeftMouseReleaseForTesting(),
            "Dragging across the find overlay must keep terminal selection ownership until mouseUp"
        )

        overlay.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: overlayLocation, window: window))
        #expect(
            !hostedView.debugSurfaceHasPendingLeftMouseReleaseForTesting(),
            "An overlay-captured mouseUp must release the terminal selection"
        )
    }

    @Test("Search overlay release clears pending selection after surface release")
    func searchOverlayMouseReleaseClearsSelectionDragAfterSurfaceRelease() async throws {
        let surface = makeTerminalSurface()
        defer { surface.releaseSurfaceForTesting() }

        let (hostedView, window) = try attachToWindow(surface: surface)
        defer { window.orderOut(nil) }

        hostedView.setSearchOverlay(searchState: TerminalSurface.SearchState(needle: "needle"))
        #expect(await waitUntil(description: "search overlay to mount") {
            hostedView.debugHasSearchOverlay()
        })

        let terminalView = try #require(surfaceView(in: hostedView) as? GhosttyNSView)
        let overlay = try #require(hostedView.debugSearchOverlayHostingViewForTesting())

        let downLocation = terminalView.convert(NSPoint(x: 24, y: 24), to: nil)
        terminalView.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: downLocation, window: window))
        #expect(hostedView.debugSurfaceHasPendingLeftMouseReleaseForTesting())

        surface.releaseSurfaceForTesting()
        #expect(surface.surface == nil)

        let overlayLocation = overlay.convert(NSPoint(x: overlay.bounds.midX, y: overlay.bounds.midY), to: nil)
        overlay.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: overlayLocation, window: window))
        #expect(
            !hostedView.debugSurfaceHasPendingLeftMouseReleaseForTesting(),
            "The pending terminal release state must clear even if the Ghostty surface is gone"
        )
    }

    private func makeTerminalSurface() -> TerminalSurface {
        TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
    }

    private func attachToWindow(surface: TerminalSurface) throws -> (GhosttySurfaceScrollView, NSWindow) {
        let hostedView = surface.hostedView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = try #require(window.contentView)
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()

        return (hostedView, window)
    }

    private func makeMouseEvent(type: NSEvent.EventType, location: NSPoint, window: NSWindow) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            preconditionFailure("Failed to create \(type) mouse event")
        }
        return event
    }

    private func surfaceView(in hostedView: GhosttySurfaceScrollView) -> NSView? {
        hostedView.subviews
            .compactMap { $0 as? NSScrollView }
            .first?
            .documentView?
            .subviews
            .first
    }

    /// Waits for the search overlay to mount.
    ///
    /// `setSearchOverlay` does not add the overlay as a subview synchronously. It stores the
    /// hosting view and posts the `addSubview` to the main queue through
    /// `scheduleDeferredSearchOverlayMutation`, so `debugHasSearchOverlay()` stays false until a
    /// later main-queue turn. This suite is `@MainActor`, so the test body holds the main thread,
    /// and the old bounded `RunLoop.current` spin never let the queued mount run. Suspending with
    /// `Task.sleep` yields the main thread so the queued mount can execute.
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        description: String,
        _ condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
