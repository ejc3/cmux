import AppKit
import SwiftUI
import Testing
@testable import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Pins the bonsplit assumptions the sizing design depends on, against the REAL
/// renderer — not a model. The pure layout tests prove the plan computes the
/// right per-pane point extents; these prove the thing that turns those extents
/// into pixels actually honors them:
///
///  1. `setImposedFirstExtent(X)` drives the first pane's real NSView frame to
///     X — placement is our computed extent, applied by bonsplit.
///  2. The remote-tmux embedded config's `minimumPaneWidth/Height = 1` means
///     even a tiny (one-cell-ish) extent is NOT clamped up — the design allows
///     1-cell tmux panes, so bonsplit must not impose a larger floor.
///  3. Panes tile their container (first + divider + second == available), so
///     the imposed split is space-filling with no gap or overrun.
///
/// If bonsplit ever regressed to clamp impositions or ignore them, the pure
/// tests would stay green while the app wrapped; this catches that.
@MainActor
@Suite struct RemoteTmuxBonsplitImpositionRenderTests {
    private func firstDescendant<T: NSView>(ofType type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for sub in root.subviews {
            if let match = firstDescendant(ofType: type, in: sub) { return match }
        }
        return nil
    }

    /// Builds a horizontal two-pane controller with the real embedded config,
    /// hosts it in a fixed-size window, and returns the live NSSplitView plus
    /// the split's UUID and the available (post-divider) width.
    private func makeHostedHorizontalSplit(
        windowWidth: CGFloat = 400,
        windowHeight: CGFloat = 300
    ) throws -> (controller: BonsplitController, window: NSWindow, splitView: NSSplitView, splitId: UUID, available: CGFloat) {
        let controller = BonsplitController(configuration: BonsplitConfiguration().remoteTmuxEmbedded)
        let rootPane = try #require(controller.allPaneIds.first)
        _ = controller.createTab(title: "left", icon: "terminal", kind: "terminal", inPane: rootPane)
        let rightPane = try #require(
            controller.splitPane(rootPane, orientation: .horizontal, withTab: nil, initialDividerPosition: 0.5)
        )
        _ = controller.createTab(title: "right", icon: "terminal", kind: "terminal", inPane: rightPane)

        guard case .split(let split) = controller.treeSnapshot() else {
            throw TestError.notASplit
        }
        let splitId = try #require(UUID(uuidString: split.id))

        let hostingView = NSHostingView(
            rootView: BonsplitView(controller: controller) { _, _ in Color.clear }
                emptyPane: { _ in Color.clear }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        let contentView = try #require(window.contentView)
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)
        window.makeKeyAndOrderFront(nil)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        let splitView = try #require(firstDescendant(ofType: NSSplitView.self, in: hostingView))
        #expect(splitView.arrangedSubviews.count == 2)
        let available = max(splitView.frame.width - splitView.dividerThickness, 1)
        return (controller, window, splitView, splitId, available)
    }

    private enum TestError: Error { case notASplit }

    /// Impose the extent, then pump the runloop until the first pane's real
    /// frame converges (the imposed apply defers a runloop turn and has a
    /// bounded AppKit retry). Returns the settled first/second widths.
    private func settleImposed(
        _ extent: CGFloat,
        controller: BonsplitController,
        splitId: UUID,
        splitView: NSSplitView,
        contentView: NSView
    ) -> (first: CGFloat, second: CGFloat) {
        _ = controller.setImposedFirstExtent(extent, forSplit: splitId)
        for _ in 0..<12 {
            splitView.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            contentView.layoutSubtreeIfNeeded()
            if abs(splitView.arrangedSubviews[0].frame.width - extent) <= 1 { break }
        }
        return (
            splitView.arrangedSubviews[0].frame.width,
            splitView.arrangedSubviews[1].frame.width
        )
    }

    /// Render ownership against the real renderer: a container change under a
    /// held imposition must NOT be fought. Bonsplit used to re-assert the old
    /// extent from its resize callback (inside the very layout pass that moved
    /// the frames — the recursive storm) and from update passes whenever the
    /// divider had "moved". Under one-writer, the stale extent stays wherever
    /// AppKit's proportional resize put it until a FRESH imposition — the
    /// authority re-planning from fresh inputs — retargets it exactly.
    @Test func containerChangeUnderImpositionIsNotFoughtUntilReimposed() throws {
        let host = try makeHostedHorizontalSplit()
        defer { host.window.orderOut(nil) }
        let contentView = try #require(host.window.contentView)

        let imposed = CGFloat(120)
        let settled = settleImposed(
            imposed, controller: host.controller, splitId: host.splitId,
            splitView: host.splitView, contentView: contentView
        )
        #expect(abs(settled.first - imposed) <= 1.5)

        // Shrink the hosting window: AppKit rescales the split proportionally.
        host.window.setContentSize(NSSize(width: 300, height: 300))
        for _ in 0..<12 {
            contentView.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let afterShrink = host.splitView.arrangedSubviews[0].frame.width
        #expect(
            afterShrink < imposed - 4,
            "stale imposition re-asserted after container change: first pane held \(afterShrink)pt (imposed \(imposed))"
        )

        // The authority retargets: a fresh imposition applies exactly.
        let reimposed = settleImposed(
            90, controller: host.controller, splitId: host.splitId,
            splitView: host.splitView, contentView: contentView
        )
        #expect(abs(reimposed.first - 90) <= 1.5)
    }

    @Test func imposedExtentDrivesRealFrameAndIsSpaceFilling() throws {
        let host = try makeHostedHorizontalSplit()
        defer { host.window.orderOut(nil) }
        let contentView = try #require(host.window.contentView)

        // A tiny extent (a ~1-cell pane), the middle, and a large extent. The
        // tiny case is the important one: min-pane=1pt must not clamp it up.
        for imposed in [CGFloat(8), 120, host.available / 2, host.available - 12] {
            let widths = settleImposed(
                imposed, controller: host.controller, splitId: host.splitId,
                splitView: host.splitView, contentView: contentView
            )
            #expect(
                abs(widths.first - imposed) <= 1.5,
                "imposed \(imposed)pt but first pane rendered \(widths.first)pt (min-pane clamp or ignored imposition?)"
            )
            #expect(
                abs((widths.first + widths.second) - host.available) <= 2.0,
                "panes do not tile: \(widths.first)+\(widths.second) != available \(host.available)"
            )
        }
    }
}
