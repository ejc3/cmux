import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Unit coverage for ``RemoteTmuxSessionChannel`` — the per-session scoping view over
/// a shared per-host control stream used when one `tmux -CC` connection multiplexes
/// several of a host's sessions. The channel must present exactly one session's
/// windows/panes to a ``RemoteTmuxSessionMirror``, filter live output to that session's
/// panes, and size each of its windows independently — proven here against a
/// programmable fake stream so no live ssh is needed.
@MainActor
@Suite(.serialized) struct RemoteTmuxSessionChannelTests {

    /// A programmable `RemoteTmuxSessionSource` standing in for the shared per-host
    /// stream: tests drive its topology and inject events, and assert on the commands
    /// the channel forwards.
    @MainActor
    final class FakeSource: RemoteTmuxSessionSource {
        var connectionState: RemoteTmuxConnectionState = .connected
        var exited = false
        var sessionId: Int?
        var windowsByID: [Int: RemoteTmuxWindow] = [:]
        var windowOrder: [Int] = []
        var activePaneByWindow: [Int: Int] = [:]
        var paneForegroundStates: [Int: RemoteTmuxPaneForegroundState] = [:]

        private(set) var observers: [UUID: RemoteTmuxSessionObservers] = [:]
        var observerCount: Int { observers.count }

        private(set) var sent: [String] = []
        private(set) var sentKeys: [(paneId: Int, data: Data)] = []
        private(set) var resizes: [(windowId: Int, cols: Int, rows: Int)] = []
        private(set) var clientSizes: [(cols: Int, rows: Int)] = []
        private(set) var seeded: [Int] = []
        private(set) var unsubscribedPath: [Int] = []
        private(set) var unsubscribedReflow: [Int] = []

        func addObserver(_ observers: RemoteTmuxSessionObservers) -> UUID {
            let token = UUID()
            self.observers[token] = observers
            return token
        }
        func removeObserver(_ token: UUID) { observers[token] = nil }

        @discardableResult func send(_ command: String) -> Bool { sent.append(command); return true }
        @discardableResult func sendKeys(paneId: Int, data: Data) -> Bool { sentKeys.append((paneId, data)); return true }
        func seedPane(paneId: Int) { seeded.append(paneId) }
        func unsubscribePanePath(paneId: Int) { unsubscribedPath.append(paneId) }
        func unsubscribePaneReflow(paneId: Int) { unsubscribedReflow.append(paneId) }
        func setClientSize(columns: Int, rows: Int) { clientSizes.append((columns, rows)) }
        func resizeWindow(windowId: Int, columns: Int, rows: Int) { resizes.append((windowId, columns, rows)) }
        func setSessionName(_ name: String) {}
        private(set) var reorders: [[Int]] = []
        func applyWindowReorder(_ reordered: [Int]) { reorders.append(reordered) }
        func queryWindowActivity(windowId: Int, completion: @escaping ([Int: RemoteTmuxPaneForegroundState]?) -> Void) { completion(nil) }
        func queryPaneActivity(paneId: Int, completion: @escaping ([Int: RemoteTmuxPaneForegroundState]?) -> Void) { completion(nil) }
        @discardableResult func pastePane(paneId: Int, text: String) -> Bool { true }

        // Event injection (fans to every registered observer, like the real stream).
        func emitPaneOutput(_ paneId: Int, _ data: Data) { for o in observers.values { o.onPaneOutput?(paneId, data) } }
        func emitPaneCwd(_ paneId: Int, _ path: String) { for o in observers.values { o.onPaneCwd?(paneId, path) } }
        func emitPaneReflow(_ paneId: Int, _ noReflow: Bool) { for o in observers.values { o.onPaneReflow?(paneId, noReflow) } }
        func emitActivePaneChanged(_ windowId: Int, _ paneId: Int) { for o in observers.values { o.onActivePaneChanged?(windowId, paneId) } }
        func emitSessionChanged(_ oldName: String, _ newName: String) { for o in observers.values { o.onSessionChanged?(oldName, newName) } }
        func emitTopologyChanged() { for o in observers.values { o.onTopologyChanged?() } }
        func emitExit() { for o in observers.values { o.onExit?() } }
        func emitConnectionStateChanged(_ state: RemoteTmuxConnectionState) { for o in observers.values { o.onConnectionStateChanged?(state) } }
    }

    private func leafWindow(id: Int, pane: Int) -> RemoteTmuxWindow {
        RemoteTmuxWindow(
            id: id, width: 80, height: 24,
            layout: RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(pane))
        )
    }

    /// A window with a horizontal split, so `ownsPane` must look past the first pane.
    private func splitWindow(id: Int, panes: [Int]) -> RemoteTmuxWindow {
        let leaves = panes.map {
            RemoteTmuxLayoutNode(width: 40, height: 24, x: 0, y: 0, content: .pane($0))
        }
        return RemoteTmuxWindow(
            id: id, width: 80, height: 24,
            layout: RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .horizontal(leaves))
        )
    }

    /// A fake host stream carrying two sessions: A owns window 1 (pane 11), B owns
    /// window 2 (pane 22).
    private func makeFake() -> FakeSource {
        let fake = FakeSource()
        fake.windowsByID = [1: leafWindow(id: 1, pane: 11), 2: leafWindow(id: 2, pane: 22)]
        fake.windowOrder = [1, 2]
        fake.activePaneByWindow = [1: 11, 2: 22]
        return fake
    }

    private func channelForA(_ fake: FakeSource) -> RemoteTmuxSessionChannel {
        RemoteTmuxSessionChannel(underlying: fake, sessionName: "A", sessionId: 3, windowIds: [1])
    }

    @Test func readsAreScopedToSessionWindows() {
        let fake = makeFake()
        let channel = channelForA(fake)
        #expect(Array(channel.windowsByID.keys) == [1])
        #expect(channel.windowOrder == [1])
        #expect(channel.activePaneByWindow == [1: 11])
        #expect(channel.sessionId == 3)
    }

    @Test func outputIsDeliveredOnlyForOwnedPanes() {
        let fake = makeFake()
        let channel = channelForA(fake)
        var received: [Int] = []
        _ = channel.addObserver(RemoteTmuxSessionObservers(onPaneOutput: { paneId, _ in received.append(paneId) }))
        fake.emitPaneOutput(11, Data("hi".utf8))   // owned (window 1)
        fake.emitPaneOutput(22, Data("no".utf8))   // other session (window 2)
        #expect(received == [11])
    }

    @Test func activePaneChangeFiltersByWindow() {
        let fake = makeFake()
        let channel = channelForA(fake)
        var seen: [Int] = []
        _ = channel.addObserver(RemoteTmuxSessionObservers(onActivePaneChanged: { windowId, _ in seen.append(windowId) }))
        fake.emitActivePaneChanged(1, 11)   // owned
        fake.emitActivePaneChanged(2, 22)   // other
        #expect(seen == [1])
    }

    @Test func setClientSizeResizesEachOwnedWindow() {
        let fake = makeFake()
        let channel = channelForA(fake)
        channel.setClientSize(columns: 100, rows: 40)
        #expect(fake.resizes.count == 1)
        #expect(fake.resizes.first?.windowId == 1)
        #expect(fake.resizes.first?.cols == 100)
        #expect(fake.resizes.first?.rows == 40)
        #expect(fake.clientSizes.isEmpty)   // never sizes via the shared client
    }

    @Test func resizeWindowIgnoresForeignWindowAndForwardsOwned() {
        let fake = makeFake()
        let channel = channelForA(fake)
        channel.resizeWindow(windowId: 2, columns: 100, rows: 40)   // window 2 belongs to B
        #expect(fake.resizes.isEmpty)
        channel.resizeWindow(windowId: 1, columns: 100, rows: 40)
        #expect(fake.resizes.count == 1)
        #expect(fake.resizes.first?.windowId == 1)
        #expect(fake.resizes.first?.cols == 100)
        #expect(fake.resizes.first?.rows == 40)
    }

    @Test func paneForegroundStatesAreScopedToOwnedPanes() {
        let fake = makeFake()
        fake.paneForegroundStates = [
            11: RemoteTmuxPaneForegroundState(rawValue: "0|vim"),
            22: RemoteTmuxPaneForegroundState(rawValue: "1|top"),
        ]
        let channel = channelForA(fake)
        #expect(Array(channel.paneForegroundStates.keys) == [11])
    }

    @Test func ownsPaneCoversNonFirstPaneOfAnOwnedSplit() {
        let fake = FakeSource()
        fake.windowsByID = [1: splitWindow(id: 1, panes: [11, 12]), 2: leafWindow(id: 2, pane: 22)]
        fake.windowOrder = [1, 2]
        let channel = RemoteTmuxSessionChannel(underlying: fake, sessionName: "A", sessionId: 3, windowIds: [1])
        var received: [Int] = []
        _ = channel.addObserver(RemoteTmuxSessionObservers(onPaneOutput: { paneId, _ in received.append(paneId) }))
        fake.emitPaneOutput(12, Data())   // second pane of owned split window 1
        fake.emitPaneOutput(22, Data())   // foreign session
        #expect(received == [12])
    }

    @Test func cwdAndReflowAreFilteredByOwnedPanes() {
        let fake = makeFake()
        let channel = channelForA(fake)
        var cwds: [Int] = []
        var reflows: [Int] = []
        _ = channel.addObserver(RemoteTmuxSessionObservers(
            onPaneCwd: { paneId, _ in cwds.append(paneId) },
            onPaneReflow: { paneId, _ in reflows.append(paneId) }
        ))
        fake.emitPaneCwd(11, "/home")   // owned
        fake.emitPaneCwd(22, "/other")  // foreign
        fake.emitPaneReflow(11, true)   // owned
        fake.emitPaneReflow(22, false)  // foreign
        #expect(cwds == [11])
        #expect(reflows == [11])
    }

    @Test func outputForUnknownPaneIsDroppedWithoutCrash() {
        let fake = makeFake()
        let channel = channelForA(fake)
        var received: [Int] = []
        _ = channel.addObserver(RemoteTmuxSessionObservers(onPaneOutput: { paneId, _ in received.append(paneId) }))
        fake.emitPaneOutput(99, Data())   // pane in no window at all
        fake.emitPaneOutput(11, Data())   // owned
        #expect(received == [11])
    }

    @Test func connectionStateAndExitedDelegateToUnderlying() {
        let fake = makeFake()
        let channel = channelForA(fake)
        #expect(channel.connectionState == .connected)
        #expect(channel.exited == false)
        fake.connectionState = .reconnecting
        fake.exited = true
        #expect(channel.connectionState == .reconnecting)
        #expect(channel.exited == true)
    }

    @Test func connectionStateChangeFansToChannel() {
        let fake = makeFake()
        let channel = channelForA(fake)
        var states: [RemoteTmuxConnectionState] = []
        _ = channel.addObserver(RemoteTmuxSessionObservers(onConnectionStateChanged: { states.append($0) }))
        fake.emitConnectionStateChanged(.reconnecting)
        #expect(states == [.reconnecting])
    }

    @Test func sessionChangedFromSharedStreamIsSwallowed() {
        let fake = makeFake()
        let channel = channelForA(fake)
        var renames = 0
        _ = channel.addObserver(RemoteTmuxSessionObservers(onSessionChanged: { _, _ in renames += 1 }))
        fake.emitSessionChanged("view", "view2")   // describes the hidden view session, not ours
        #expect(renames == 0)
    }

    @Test func applyWindowReorderFiltersForeignWindowIds() {
        let fake = makeFake()
        let channel = RemoteTmuxSessionChannel(underlying: fake, sessionName: "A", sessionId: 3, windowIds: [1, 5])
        channel.applyWindowReorder([5, 1, 2])   // 2 belongs to a sibling session
        #expect(fake.reorders == [[5, 1]])       // foreign id dropped before it reaches the shared order
    }

    @Test func unsubscribeCommandsPassThrough() {
        let fake = makeFake()
        let channel = channelForA(fake)
        channel.unsubscribePanePath(paneId: 11)
        channel.unsubscribePaneReflow(paneId: 11)
        #expect(fake.unsubscribedPath == [11])
        #expect(fake.unsubscribedReflow == [11])
    }

    @Test func lastClientSizeIsReplayedOntoNewlyOwnedWindows() {
        let fake = makeFake()
        let channel = channelForA(fake)          // owns window 1
        channel.setClientSize(columns: 100, rows: 40)
        #expect(fake.resizes.count == 1)          // window 1 only
        channel.updateWindowIds([1, 2])           // window 2 becomes owned
        // window 2 gets the remembered size without a fresh setClientSize call.
        #expect(fake.resizes.contains { $0.windowId == 2 && $0.cols == 100 && $0.rows == 40 })
    }

    @Test func updateWindowIdsRescopesAndNotifies() {
        let fake = makeFake()
        let channel = channelForA(fake)
        var topologyBumps = 0
        _ = channel.addObserver(RemoteTmuxSessionObservers(onTopologyChanged: { topologyBumps += 1 }))
        channel.updateWindowIds([1, 2])
        #expect(topologyBumps == 1)
        #expect(Set(channel.windowOrder) == [1, 2])
        // A no-op update (same set) must not re-notify.
        channel.updateWindowIds([1, 2])
        #expect(topologyBumps == 1)
        // Pane 22 is now owned, so its output fans through.
        var received: [Int] = []
        _ = channel.addObserver(RemoteTmuxSessionObservers(onPaneOutput: { paneId, _ in received.append(paneId) }))
        fake.emitPaneOutput(22, Data())
        #expect(received == [22])
        // Shrinking the set back re-notifies and stops fanning the dropped window's panes.
        channel.updateWindowIds([1])
        #expect(topologyBumps == 2)
        received.removeAll()
        fake.emitPaneOutput(22, Data())   // window 2 no longer owned
        fake.emitPaneOutput(11, Data())   // window 1 still owned
        #expect(received == [11])
    }

    @Test func detachRemovesUnderlyingObserverAndStopsFanning() {
        let fake = makeFake()
        let channel = channelForA(fake)
        #expect(fake.observerCount == 1)
        channel.detach()
        #expect(fake.observerCount == 0)
        var received = 0
        _ = channel.addObserver(RemoteTmuxSessionObservers(onPaneOutput: { _, _ in received += 1 }))
        fake.emitPaneOutput(11, Data())
        #expect(received == 0)
    }

    @Test func commandsPassThroughToUnderlying() {
        let fake = makeFake()
        let channel = channelForA(fake)
        _ = channel.send("split-window")
        _ = channel.sendKeys(paneId: 11, data: Data("x".utf8))
        channel.seedPane(paneId: 11)
        #expect(fake.sent == ["split-window"])
        #expect(fake.sentKeys.count == 1)
        #expect(fake.sentKeys.first?.paneId == 11)
        #expect(fake.seeded == [11])
    }

    @Test func hostExitFansToChannel() {
        let fake = makeFake()
        let channel = channelForA(fake)
        var exits = 0
        _ = channel.addObserver(RemoteTmuxSessionObservers(onExit: { exits += 1 }))
        fake.emitExit()
        #expect(exits == 1)
    }

    @Test func twoChannelsSplitOneStreamWithoutCrosstalk() {
        let fake = makeFake()
        let a = RemoteTmuxSessionChannel(underlying: fake, sessionName: "A", sessionId: 3, windowIds: [1])
        let b = RemoteTmuxSessionChannel(underlying: fake, sessionName: "B", sessionId: 4, windowIds: [2])
        var aPanes: [Int] = []
        var bPanes: [Int] = []
        _ = a.addObserver(RemoteTmuxSessionObservers(onPaneOutput: { paneId, _ in aPanes.append(paneId) }))
        _ = b.addObserver(RemoteTmuxSessionObservers(onPaneOutput: { paneId, _ in bPanes.append(paneId) }))
        fake.emitPaneOutput(11, Data())
        fake.emitPaneOutput(22, Data())
        #expect(aPanes == [11])
        #expect(bPanes == [22])
        #expect(a.windowOrder == [1])
        #expect(b.windowOrder == [2])
    }
}
