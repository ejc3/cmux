import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A mirrored host with hundreds of windows must not pay per-window work for an event that
/// touches one window, or none. Each test publishes `windowCount` single-pane windows on a real
/// ``RemoteTmuxControlConnection`` and then counts what one event costs: list-windows and
/// pane-rects requests queued, topology notifications, and the session channel's fan-outs (each
/// fan-out is one mirror rebuild). The counts are the contract; nothing here measures time.
@MainActor
@Suite struct RemoteTmuxManyWindowsChurnTests {
    private static let windowCount = 800

    private func paneId(_ windowId: Int) -> Int { windowId * 10 }

    private func layout(_ windowId: Int, columns: Int = 80, rows: Int = 24) -> String {
        "f92f,\(columns)x\(rows),0,0,\(paneId(windowId))"
    }

    private func windowLine(_ windowId: Int, columns: Int = 80, rows: Int = 24) -> String {
        let layout = layout(windowId, columns: columns, rows: rows)
        return "@\(windowId) \(layout) \(layout) [] window-\(windowId)"
    }

    private func rectsLine(_ windowId: Int, columns: Int = 80, rows: Int = 24) -> String {
        "%\(paneId(windowId)) 0 0 \(columns) \(rows) 1 off :shell"
    }

    private func attachedConnection() -> (
        connection: RemoteTmuxControlConnection,
        writer: RemoteTmuxControlPipeWriter,
        pipe: Pipe
    ) {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"), sessionName: "work"
        )
        let pipe = Pipe()
        // The connection writes every request to this pipe and nothing reads it, so give it room
        // for the requests a few hundred windows generate.
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-many-windows-test",
            maxPendingBytes: 1 << 26,
            onFailure: {}
        )
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        connection.handleMessageForTesting(
            .commandResult(commandNumber: 0, lines: [], isError: false)
        )
        return (connection, writer, pipe)
    }

    private func reply(_ connection: RemoteTmuxControlConnection, lines: [String]) {
        connection.handleMessageForTesting(
            .commandResult(commandNumber: 0, lines: lines, isError: false)
        )
    }

    private func paneRectsWindows(_ connection: RemoteTmuxControlConnection) -> [Int] {
        connection.pendingCommandKindsForTesting.compactMap {
            if case let .paneRects(windowId, _) = $0 { return windowId }
            return nil
        }
    }

    private func listWindowsCount(_ connection: RemoteTmuxControlConnection) -> Int {
        connection.pendingCommandKindsForTesting.filter {
            if case .listWindows = $0 { return true }
            return false
        }.count
    }

    /// Answers every queued command the way tmux would for the current windows, until the FIFO is
    /// empty, and returns how many pane-rects requests it answered.
    @discardableResult
    private func drain(
        _ connection: RemoteTmuxControlConnection,
        windows: [Int],
        columns: Int = 80,
        rows: Int = 24
    ) -> Int {
        var rectsAnswered = 0
        var guardCount = 0
        while let kind = connection.pendingCommandKindsForTesting.first, guardCount < 20 * Self.windowCount {
            guardCount += 1
            switch kind {
            case let .paneRects(windowId, _):
                rectsAnswered += 1
                reply(connection, lines: [rectsLine(windowId, columns: columns, rows: rows)])
            case .listWindows:
                reply(connection, lines: windows.map { windowLine($0, columns: columns, rows: rows) })
            default:
                reply(connection, lines: [])
            }
        }
        return rectsAnswered
    }

    /// Publishes windows `1...windowCount` and leaves the FIFO empty.
    private func publishManyWindows(_ connection: RemoteTmuxControlConnection) -> [Int] {
        let windows = Array(1...Self.windowCount)
        reply(connection, lines: windows.map { windowLine($0) })
        drain(connection, windows: windows)
        return windows
    }

    /// A session channel over the connection that owns every window, plus a counter of its
    /// topology fan-outs. The mirror rebuilds once per fan-out.
    private func channelRebuildCounter(
        _ connection: RemoteTmuxControlConnection, windows: [Int]
    ) -> (channel: RemoteTmuxSessionChannel, rebuilds: () -> Int) {
        let channel = RemoteTmuxSessionChannel(
            underlying: connection, sessionName: "work", sessionId: 1, windowIds: []
        )
        // Scoping after construction records the channel's current topology as its baseline, the
        // way the view coordinator scopes a live channel, so only a later change fans out.
        channel.updateWindowIds(windows)
        final class Counter { var value = 0 }
        let counter = Counter()
        _ = channel.addObserver(RemoteTmuxSessionObservers(
            onPaneOutput: nil, onPaneSeed: nil, onPaneCwd: nil, onPaneReflow: nil,
            onPaneTitleChanged: nil, onActivePaneChanged: nil, onSessionChanged: nil,
            onPaneAgent: nil,
            onTopologyChanged: { counter.value += 1 },
            onReconnectReady: nil, onExit: nil, onConnectionStateChanged: nil, onAuthRequired: nil
        ))
        return (channel, { counter.value })
    }

    /// One tmux command reply block as it arrives on the wire.
    private func replyBlock(number: Int, lines: [String]) -> String {
        "%begin 1700000000 \(number) 1\r\n"
            + lines.map { $0 + "\r\n" }.joined()
            + "%end 1700000000 \(number) 1\r\n"
    }

    // MARK: - A window cmux never had

    /// Another tmux session opens a window and it closes before cmux ever lists it. That close
    /// says nothing about the windows cmux mirrors, so it must not re-list them, and a re-list
    /// must not refetch every window's pane rects.
    @Test func closeOfAWindowCmuxNeverHadQueuesNoWindowListAndNoRects() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        let windows = publishManyWindows(connection)
        let (channel, rebuilds) = channelRebuildCounter(connection, windows: windows)
        defer { channel.detach() }
        // The shared view stream is the client that sees every other session's windows.
        connection.isSharedViewStream = true

        let unrelated = Self.windowCount + 1000
        connection.handleMessageForTesting(.unlinkedWindowAdd(windowId: unrelated))
        connection.handleMessageForTesting(.windowClose(windowId: unrelated))

        #expect(listWindowsCount(connection) == 0)
        let rectsRequested = drain(connection, windows: windows)
        #expect(rectsRequested == 0)
        #expect(rebuilds() == 0)
        #expect(connection.windowOrder.count == Self.windowCount)
    }

    /// The re-list stays for a window cmux published: a move of a window's final pane reports the
    /// source close before the destination layout, and the re-list is what reconciles it.
    @Test func closeOfAPublishedWindowStillReListsWindows() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        _ = publishManyWindows(connection)

        connection.handleMessageForTesting(.windowClose(windowId: 7))

        #expect(listWindowsCount(connection) == 1)
        #expect(connection.windowsByID[7] == nil)
    }

    /// A window that is still waiting for its first rects reply is known to cmux, so its close
    /// re-lists too.
    @Test func closeOfAWindowAwaitingItsRectsStillReListsWindows() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        var windows = publishManyWindows(connection)

        let added = Self.windowCount + 1
        windows.append(added)
        connection.handleMessageForTesting(.windowAdd(windowId: added))
        // Answer the list-windows only; the new window's rects fetch stays in flight.
        while let kind = connection.pendingCommandKindsForTesting.first {
            if case .listWindows = kind {
                reply(connection, lines: windows.map { windowLine($0) })
                break
            }
            reply(connection, lines: [])
        }
        #expect(connection.pendingLayouts[added] != nil)

        connection.handleMessageForTesting(.windowClose(windowId: added))

        #expect(listWindowsCount(connection) == 1)
    }

    /// On a first attach, a window whose rects reply already landed waits in the initial batch
    /// for the others. It is known to cmux, so its close re-lists.
    @Test func closeOfAWindowStagedInTheInitialBatchStillReListsWindows() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }

        reply(connection, lines: [windowLine(1), windowLine(2)])
        while let kind = connection.pendingCommandKindsForTesting.first {
            if case let .paneRects(windowId, _) = kind {
                reply(connection, lines: [rectsLine(windowId)])
                break
            }
            reply(connection, lines: [])
        }
        #expect(connection.windowsByID.isEmpty)
        let staged = connection.pendingLayouts[1] == nil ? 1 : 2

        connection.handleMessageForTesting(.windowClose(windowId: staged))

        #expect(listWindowsCount(connection) == 1)
    }

    // MARK: - Re-lists with unchanged layouts

    /// A re-list (here for one new window) reports every other window with the layout cmux
    /// already published. Only the new window needs its pane rects.
    @Test func windowListWithUnchangedLayoutsFetchesRectsOnlyForTheNewWindow() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        var windows = publishManyWindows(connection)
        let (channel, rebuilds) = channelRebuildCounter(connection, windows: windows)
        defer { channel.detach() }

        let added = Self.windowCount + 1
        windows.append(added)
        connection.handleMessageForTesting(.windowAdd(windowId: added))
        while let kind = connection.pendingCommandKindsForTesting.first {
            if case .listWindows = kind {
                reply(connection, lines: windows.map { windowLine($0) })
                break
            }
            reply(connection, lines: [])
        }

        #expect(paneRectsWindows(connection) == [added])
        drain(connection, windows: windows)
        #expect(connection.windowsByID[added] != nil)
        // The channel still owns only the original windows, so the new one changes nothing it shows.
        #expect(rebuilds() == 0)
    }

    /// A re-list that reports a changed layout refetches that window, and only that window.
    @Test func windowListRefetchesRectsOnlyForAChangedLayout() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        let windows = publishManyWindows(connection)

        connection.handleMessageForTesting(.windowAdd(windowId: 9999))
        while let kind = connection.pendingCommandKindsForTesting.first {
            if case .listWindows = kind {
                reply(connection, lines: windows.map {
                    $0 == 7 ? windowLine($0, columns: 120, rows: 40) : windowLine($0)
                })
                break
            }
            reply(connection, lines: [])
        }

        #expect(paneRectsWindows(connection) == [7])
        reply(connection, lines: [rectsLine(7, columns: 120, rows: 40)])
        #expect(connection.windowsByID[7]?.width == 120)
    }

    /// `pane-border-status` moves pane rows without changing the layout string. Its change must
    /// still refetch that window's rects even though the re-list reports the same layout.
    @Test func borderStatusChangeStillRefetchesItsWindowsRects() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        let windows = publishManyWindows(connection)

        connection.handleMessageForTesting(.subscriptionChanged(
            name: RemoteTmuxControlConnection.borderStatusSubscriptionPrefix + "7", value: "top"
        ))
        while let kind = connection.pendingCommandKindsForTesting.first {
            if case .listWindows = kind {
                reply(connection, lines: windows.map { windowLine($0) })
                break
            }
            reply(connection, lines: [])
        }

        #expect(paneRectsWindows(connection).contains(7))
        #expect(paneRectsWindows(connection).count <= 1)
    }

    /// tmux reports `%layout-change` for every window when one window's size changes. A window
    /// whose layout did not change needs no rects fetch.
    @Test func identicalLayoutChangeFetchesNoRects() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        let windows = publishManyWindows(connection)

        for window in windows {
            connection.handleMessageForTesting(.layoutChange(
                windowId: window, layout: layout(window), visibleLayout: layout(window), zoomed: false
            ))
        }

        #expect(paneRectsWindows(connection).isEmpty)

        connection.handleMessageForTesting(.layoutChange(
            windowId: 7, layout: layout(7, columns: 100, rows: 30),
            visibleLayout: layout(7, columns: 100, rows: 30), zoomed: false
        ))
        #expect(paneRectsWindows(connection) == [7])
    }

    /// While a fetch for a newer layout is in flight, a layout that matches the published tree
    /// again is still a change from what is pending, so it must be fetched rather than skipped.
    @Test func layoutReturningToThePublishedTreeWhileAFetchIsInFlightStillRefetches() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        _ = publishManyWindows(connection)

        connection.handleMessageForTesting(.layoutChange(
            windowId: 7, layout: layout(7, columns: 100, rows: 30),
            visibleLayout: layout(7, columns: 100, rows: 30), zoomed: false
        ))
        connection.handleMessageForTesting(.layoutChange(
            windowId: 7, layout: layout(7), visibleLayout: layout(7), zoomed: false
        ))
        #expect(connection.pendingLayouts[7]?.node == RemoteTmuxRawLayoutParser.parse(layout(7)))

        reply(connection, lines: [rectsLine(7, columns: 100, rows: 30)])
        // The stale reply publishes and owes one follow-up for the current tree.
        #expect(paneRectsWindows(connection) == [7])
        reply(connection, lines: [rectsLine(7)])
        #expect(connection.windowsByID[7]?.width == 80)
        #expect(connection.pendingLayouts[7] == nil)
    }

    // MARK: - Bursts of rects replies

    /// A size change for every window queues one rects fetch per window, and tmux answers them
    /// back to back. Replies that arrive in one read must rebuild the mirror once, not once per
    /// window.
    @Test func burstOfRectsRepliesInOneReadRebuildsTheMirrorOnce() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        let windows = publishManyWindows(connection)
        let (channel, rebuilds) = channelRebuildCounter(connection, windows: windows)
        defer { channel.detach() }
        var notifies = 0
        let token = connection.addObserver(onTopologyChanged: { notifies += 1 })
        defer { connection.removeObserver(token) }

        for window in windows {
            connection.handleMessageForTesting(.layoutChange(
                windowId: window, layout: layout(window, columns: 100, rows: 30),
                visibleLayout: layout(window, columns: 100, rows: 30), zoomed: false
            ))
        }
        let queued = paneRectsWindows(connection)
        #expect(queued.count == Self.windowCount)
        #expect(connection.pendingCommandKindsForTesting.count == queued.count)

        let wire = queued.enumerated().map { index, window in
            replyBlock(number: 100 + index, lines: [rectsLine(window, columns: 100, rows: 30)])
        }.joined()
        connection.ingest(Data(wire.utf8))

        #expect(paneRectsWindows(connection).isEmpty)
        #expect(windows.allSatisfy { connection.windowsByID[$0]?.width == 100 })
        #expect(notifies == 1)
        #expect(rebuilds() == 1)
    }

    /// Collapsing topology notifications must not reorder them against other events. A
    /// notification between two rects replies (here an active-pane change) still comes after the
    /// first window's topology notification and before the second's.
    @Test func coalescedTopologyNotificationStillPrecedesALaterNotification() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        _ = publishManyWindows(connection)
        var events: [String] = []
        let token = connection.addObserver(
            onActivePaneChanged: { windowId, paneId in events.append("active @\(windowId) %\(paneId)") },
            onTopologyChanged: { events.append("topology") }
        )
        defer { connection.removeObserver(token) }

        for window in [1, 2] {
            connection.handleMessageForTesting(.layoutChange(
                windowId: window, layout: layout(window, columns: 100, rows: 30),
                visibleLayout: layout(window, columns: 100, rows: 30), zoomed: false
            ))
        }
        let queued = paneRectsWindows(connection)
        #expect(queued == [1, 2])

        let wire = replyBlock(number: 100, lines: [rectsLine(1, columns: 100, rows: 30)])
            + "%window-pane-changed @3 %\(paneId(3))\r\n"
            + replyBlock(number: 101, lines: [rectsLine(2, columns: 100, rows: 30)])
        connection.ingest(Data(wire.utf8))

        #expect(events == ["topology", "active @3 %\(paneId(3))", "topology"])
    }

    /// A rects reply can itself report a new active pane. When that reply follows another rects
    /// reply in the same read, the earlier reply's topology notification still comes first, so
    /// observers see the same order as when every reply notified at once.
    @Test func coalescedTopologyNotificationStillPrecedesAnActivePaneChangeInALaterReply() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        _ = publishManyWindows(connection)
        var events: [String] = []
        let token = connection.addObserver(
            onActivePaneChanged: { windowId, paneId in events.append("active @\(windowId) %\(paneId)") },
            onTopologyChanged: { events.append("topology") }
        )
        defer { connection.removeObserver(token) }

        connection.handleMessageForTesting(.layoutChange(
            windowId: 1, layout: layout(1, columns: 100, rows: 30),
            visibleLayout: layout(1, columns: 100, rows: 30), zoomed: false
        ))
        let split = "a1b2,100x30,0,0{50x30,0,0,20,49x30,51,0,21}"
        connection.handleMessageForTesting(.layoutChange(
            windowId: 2, layout: split, visibleLayout: split, zoomed: false
        ))
        #expect(paneRectsWindows(connection) == [1, 2])

        let wire = replyBlock(number: 100, lines: [rectsLine(1, columns: 100, rows: 30)])
            + replyBlock(number: 101, lines: [
                "%20 0 0 50 30 0 off :shell",
                "%21 51 0 49 30 1 off :shell",
            ])
        connection.ingest(Data(wire.utf8))

        #expect(events == ["topology", "active @2 %21", "topology"])
    }

    /// A command completion that lands between two rects replies reads state the mirrors derive
    /// in their rebuild (a divider barrier judges against the rendered tree), so the first
    /// reply's topology notification must reach observers before the completion runs.
    @Test func coalescedTopologyNotificationStillPrecedesALaterCommandCompletion() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        _ = publishManyWindows(connection)
        var events: [String] = []
        let token = connection.addObserver(onTopologyChanged: { events.append("topology") })
        defer { connection.removeObserver(token) }

        connection.handleMessageForTesting(.layoutChange(
            windowId: 1, layout: layout(1, columns: 100, rows: 30),
            visibleLayout: layout(1, columns: 100, rows: 30), zoomed: false
        ))
        let sent = connection.sendTracked("display-message -p barrier", completion: { _ in
            events.append("completion")
        })
        #expect(sent)
        connection.handleMessageForTesting(.layoutChange(
            windowId: 2, layout: layout(2, columns: 100, rows: 30),
            visibleLayout: layout(2, columns: 100, rows: 30), zoomed: false
        ))
        #expect(connection.pendingCommandKindsForTesting.count == 3)

        let wire = replyBlock(number: 100, lines: [rectsLine(1, columns: 100, rows: 30)])
            + replyBlock(number: 101, lines: [])
            + replyBlock(number: 102, lines: [rectsLine(2, columns: 100, rows: 30)])
        connection.ingest(Data(wire.utf8))

        #expect(events == ["topology", "completion", "topology"])
    }
}
