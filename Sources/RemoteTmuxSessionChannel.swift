import Foundation

/// A per-session view over a shared per-host control stream.
///
/// When one `tmux -CC` connection multiplexes several of a host's sessions (a host
/// that permits only a single concurrent connection), each session gets a
/// `RemoteTmuxSessionChannel` that scopes the shared connection down to that
/// session's windows: topology reads are filtered to the session's window ids,
/// `%output`/events are delivered only for its panes, and sizing goes through
/// per-window `resizeWindow`. A `RemoteTmuxSessionMirror` therefore renders a
/// multiplexed session through the exact same `RemoteTmuxSessionSource` path it uses
/// for a dedicated per-session connection — no mirror-side special-casing.
///
/// The channel is a decorator over `any RemoteTmuxSessionSource`, so it wraps the
/// real control connection in production and a fake in tests.
@MainActor
final class RemoteTmuxSessionChannel: RemoteTmuxSessionSource {
    /// The shared per-host control stream this channel scopes.
    let underlying: any RemoteTmuxSessionSource

    /// The real tmux session id (`$N`) this channel represents, stable across renames
    /// — distinct from the shared connection's own attached (view) session id.
    private(set) var scopedSessionId: Int?
    private var scopedSessionName: String

    /// The tmux window ids that belong to this session; refreshed by the coordinator
    /// as the host's topology changes (via ``updateWindowIds(_:)``).
    private(set) var windowIds: Set<Int>

    /// The panes owned by this session's windows, derived from `windowIds` and the
    /// shared topology. Cached so the hot `%output` path is an O(1) membership test
    /// instead of rescanning every window on every output chunk; rebuilt whenever the
    /// window set or the shared topology changes.
    private var ownedPaneIds: Set<Int> = []

    /// The last client size requested for this session, replayed onto newly-owned
    /// windows so a size that arrives before `windowIds` is populated isn't lost.
    private var lastClientSize: (columns: Int, rows: Int)?

    /// This channel's own observers — a filtered fan-out of the shared stream's events.
    private var observers: [UUID: RemoteTmuxSessionObservers] = [:]
    private var underlyingToken: UUID?

    init(
        underlying: any RemoteTmuxSessionSource,
        sessionName: String,
        sessionId: Int?,
        windowIds: Set<Int>
    ) {
        self.underlying = underlying
        self.scopedSessionName = sessionName
        self.scopedSessionId = sessionId
        self.windowIds = windowIds
        recomputeOwnedPanes()
        self.underlyingToken = underlying.addObserver(makeFilteringObservers())
    }

    /// Stops fanning events and drops the shared-stream observer. Call when the
    /// session's mirror goes away so the channel doesn't outlive its use.
    func detach() {
        if let token = underlyingToken {
            underlying.removeObserver(token)
            underlyingToken = nil
        }
        observers.removeAll()
    }

    /// Refreshes the session's window set (coordinator, on reconcile), re-sizes any
    /// newly-owned windows to the last requested client size, and nudges topology
    /// observers so the mirror re-reads the now-scoped state.
    func updateWindowIds(_ ids: Set<Int>) {
        guard ids != windowIds else { return }
        windowIds = ids
        recomputeOwnedPanes()
        if let size = lastClientSize {
            for windowId in windowIds {
                underlying.resizeWindow(windowId: windowId, columns: size.columns, rows: size.rows)
            }
        }
        for o in observers.values { o.onTopologyChanged?() }
    }

    /// Records the real session id once the coordinator learns it.
    func setScopedSessionId(_ id: Int?) { scopedSessionId = id }

    // MARK: - RemoteTmuxSessionSource: scoped reads

    var connectionState: RemoteTmuxConnectionState { underlying.connectionState }
    var exited: Bool { underlying.exited }
    var sessionId: Int? { scopedSessionId }
    var windowsByID: [Int: RemoteTmuxWindow] { underlying.windowsByID.filter { windowIds.contains($0.key) } }
    var windowOrder: [Int] { underlying.windowOrder.filter { windowIds.contains($0) } }
    var activePaneByWindow: [Int: Int] { underlying.activePaneByWindow.filter { windowIds.contains($0.key) } }
    var paneForegroundStates: [Int: RemoteTmuxPaneForegroundState] { underlying.paneForegroundStates.filter { ownedPaneIds.contains($0.key) } }

    // MARK: - RemoteTmuxSessionSource: observers

    func addObserver(_ observers: RemoteTmuxSessionObservers) -> UUID {
        let token = UUID()
        self.observers[token] = observers
        return token
    }

    func removeObserver(_ token: UUID) { observers[token] = nil }

    // MARK: - RemoteTmuxSessionSource: commands (server-global @window/%pane ids pass through)

    @discardableResult func send(_ command: String) -> Bool { underlying.send(command) }
    @discardableResult func sendKeys(paneId: Int, data: Data) -> Bool { underlying.sendKeys(paneId: paneId, data: data) }
    func seedPane(paneId: Int) { underlying.seedPane(paneId: paneId) }
    func unsubscribePanePath(paneId: Int) { underlying.unsubscribePanePath(paneId: paneId) }
    func unsubscribePaneReflow(paneId: Int) { underlying.unsubscribePaneReflow(paneId: paneId) }
    func setSessionName(_ name: String) { scopedSessionName = name }
    /// Forwards a reorder of *this session's* windows, filtered to owned windows so a
    /// stale/foreign id can never reach the shared order. The underlying permutes only
    /// the listed windows and leaves other sessions' windows in place, so a scoped
    /// reorder never disturbs a sibling channel's view.
    func applyWindowReorder(_ reordered: [Int]) {
        underlying.applyWindowReorder(reordered.filter { windowIds.contains($0) })
    }
    func queryWindowActivity(windowId: Int, completion: @escaping ([Int: RemoteTmuxPaneForegroundState]?) -> Void) {
        underlying.queryWindowActivity(windowId: windowId, completion: completion)
    }
    func queryPaneActivity(paneId: Int, completion: @escaping ([Int: RemoteTmuxPaneForegroundState]?) -> Void) {
        underlying.queryPaneActivity(paneId: paneId, completion: completion)
    }
    @discardableResult func pastePane(paneId: Int, text: String) -> Bool { underlying.pastePane(paneId: paneId, text: text) }

    // MARK: - RemoteTmuxSessionSource: sizing (per-window; the view session is window-size manual)

    func setClientSize(columns: Int, rows: Int) {
        lastClientSize = (columns, rows)
        for windowId in windowIds { underlying.resizeWindow(windowId: windowId, columns: columns, rows: rows) }
    }

    func resizeWindow(windowId: Int, columns: Int, rows: Int) {
        guard windowIds.contains(windowId) else { return }
        underlying.resizeWindow(windowId: windowId, columns: columns, rows: rows)
    }

    // MARK: - Filtering fan-out

    /// Whether `paneId` belongs to one of this session's windows (output/cwd/reflow
    /// are keyed by server-global pane id). O(1) against the cached owned-pane set.
    private func ownsPane(_ paneId: Int) -> Bool { ownedPaneIds.contains(paneId) }

    /// Rebuilds `ownedPaneIds` from the current window set and shared topology.
    private func recomputeOwnedPanes() {
        var panes: Set<Int> = []
        for (windowId, window) in underlying.windowsByID where windowIds.contains(windowId) {
            for pane in window.paneIDsInOrder { panes.insert(pane) }
        }
        ownedPaneIds = panes
    }

    private func makeFilteringObservers() -> RemoteTmuxSessionObservers {
        RemoteTmuxSessionObservers(
            onPaneOutput: { [weak self] paneId, data in
                guard let self, self.ownsPane(paneId) else { return }
                for o in self.observers.values { o.onPaneOutput?(paneId, data) }
            },
            onPaneCwd: { [weak self] paneId, path in
                guard let self, self.ownsPane(paneId) else { return }
                for o in self.observers.values { o.onPaneCwd?(paneId, path) }
            },
            onPaneReflow: { [weak self] paneId, noReflow in
                guard let self, self.ownsPane(paneId) else { return }
                for o in self.observers.values { o.onPaneReflow?(paneId, noReflow) }
            },
            onActivePaneChanged: { [weak self] windowId, paneId in
                guard let self, self.windowIds.contains(windowId) else { return }
                for o in self.observers.values { o.onActivePaneChanged?(windowId, paneId) }
            },
            onSessionChanged: { _, _ in
                // The shared stream's %session-changed describes the hidden view session,
                // not this real session; per-session rename is driven by the coordinator.
            },
            onTopologyChanged: { [weak self] in
                guard let self else { return }
                self.recomputeOwnedPanes()
                for o in self.observers.values { o.onTopologyChanged?() }
            },
            onExit: {
                // Deliberately NOT fanned. The shared stream's `%exit` is host-stream
                // death; the view coordinator owns teardown for every session on the
                // host (it removes each mirror + channel and discards the window). Fanning
                // per-channel too would double-tear-down — each mirror would also run the
                // dedicated-connection end path (a one-shot kill a single-connection host
                // refuses, plus a per-session unbind), racing the coordinator. Transient
                // reconnects still reach the mirror via `onConnectionStateChanged` below.
            },
            onConnectionStateChanged: { [weak self] state in
                guard let self else { return }
                for o in self.observers.values { o.onConnectionStateChanged?(state) }
            }
        )
    }
}
