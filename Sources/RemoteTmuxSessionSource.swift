import Foundation

/// The per-session control callbacks a ``RemoteTmuxSessionMirror`` registers.
///
/// Bundled into a value type because protocol requirements can't carry default
/// parameter values: every closure defaults to `nil`, so a call site names only the
/// events it cares about, exactly as the free-function form did.
@MainActor
struct RemoteTmuxSessionObservers {
    var onPaneOutput: ((_ paneId: Int, _ data: Data) -> Void)?
    var onPaneCwd: ((_ paneId: Int, _ path: String) -> Void)?
    var onPaneReflow: ((_ paneId: Int, _ noReflow: Bool) -> Void)?
    var onActivePaneChanged: ((_ windowId: Int, _ paneId: Int) -> Void)?
    var onSessionChanged: ((_ oldName: String, _ newName: String) -> Void)?
    var onTopologyChanged: (() -> Void)?
    var onExit: (() -> Void)?
    var onConnectionStateChanged: ((RemoteTmuxConnectionState) -> Void)?

    init(
        onPaneOutput: ((_ paneId: Int, _ data: Data) -> Void)? = nil,
        onPaneCwd: ((_ paneId: Int, _ path: String) -> Void)? = nil,
        onPaneReflow: ((_ paneId: Int, _ noReflow: Bool) -> Void)? = nil,
        onActivePaneChanged: ((_ windowId: Int, _ paneId: Int) -> Void)? = nil,
        onSessionChanged: ((_ oldName: String, _ newName: String) -> Void)? = nil,
        onTopologyChanged: (() -> Void)? = nil,
        onExit: (() -> Void)? = nil,
        onConnectionStateChanged: ((RemoteTmuxConnectionState) -> Void)? = nil
    ) {
        self.onPaneOutput = onPaneOutput
        self.onPaneCwd = onPaneCwd
        self.onPaneReflow = onPaneReflow
        self.onActivePaneChanged = onActivePaneChanged
        self.onSessionChanged = onSessionChanged
        self.onTopologyChanged = onTopologyChanged
        self.onExit = onExit
        self.onConnectionStateChanged = onConnectionStateChanged
    }
}

/// The per-session view a ``RemoteTmuxSessionMirror`` (and its child window mirror)
/// consumes from its control stream: the session's window/pane topology, live output,
/// and the small command surface the mirror issues.
///
/// Today's GA per-session ``RemoteTmuxControlConnection`` conforms directly — one
/// connection is one session, so the source *is* the connection. A later shared-per-host
/// multiplexed transport supplies one of these per session over a single stream, so the
/// mirror renders a session identically whether it owns its connection or shares one.
@MainActor
protocol RemoteTmuxSessionSource: AnyObject {
    /// Live transport state (host-global under a shared connection).
    var connectionState: RemoteTmuxConnectionState { get }
    /// `true` once the session has permanently ended.
    var exited: Bool { get }
    /// The tmux session id (`$N`), stable across renames, once known.
    var sessionId: Int? { get }
    /// This session's windows, keyed by tmux window id.
    var windowsByID: [Int: RemoteTmuxWindow] { get }
    /// This session's window ids in tmux index order.
    var windowOrder: [Int] { get }
    /// The active pane per window for this session.
    var activePaneByWindow: [Int: Int] { get }
    /// Cached foreground state per pane (drives close-confirmation / activity).
    var paneForegroundStates: [Int: RemoteTmuxPaneForegroundState] { get }

    /// Registers the mirror's callbacks; returns a token for `removeObserver`.
    func addObserver(_ observers: RemoteTmuxSessionObservers) -> UUID
    func removeObserver(_ token: UUID)

    /// Sends a raw tmux control command targeting this session's server-global ids.
    @discardableResult func send(_ command: String) -> Bool
    /// Forwards typed input to a pane.
    @discardableResult func sendKeys(paneId: Int, data: Data) -> Bool
    /// Replays a pane's captured contents into a freshly-mounted surface.
    func seedPane(paneId: Int)
    /// Ends per-pane cwd / reflow subscriptions when a pane's mirror goes away.
    func unsubscribePanePath(paneId: Int)
    func unsubscribePaneReflow(paneId: Int)
    /// Sizes the control client / this session's windows.
    func setClientSize(columns: Int, rows: Int)
    /// Sizes a single window (multiplexed mode: the view session is window-size
    /// manual, so each window is sized independently rather than via the shared client).
    func resizeWindow(windowId: Int, columns: Int, rows: Int)
    /// Updates the cached session name (after a confirmed rename).
    func setSessionName(_ name: String)
    /// Applies a reordered window list to the cached order.
    func applyWindowReorder(_ reordered: [Int])
    /// Queries the foreground state of a window's panes.
    func queryWindowActivity(windowId: Int, completion: @escaping ([Int: RemoteTmuxPaneForegroundState]?) -> Void)
    /// Queries the foreground state of a single pane.
    func queryPaneActivity(paneId: Int, completion: @escaping ([Int: RemoteTmuxPaneForegroundState]?) -> Void)
    /// Pastes text into a pane.
    @discardableResult func pastePane(paneId: Int, text: String) -> Bool
}

/// GA: one control connection *is* one session, so the connection is its own source.
extension RemoteTmuxControlConnection: RemoteTmuxSessionSource {
    func addObserver(_ observers: RemoteTmuxSessionObservers) -> UUID {
        addObserver(
            onPaneOutput: observers.onPaneOutput,
            onPaneCwd: observers.onPaneCwd,
            onPaneReflow: observers.onPaneReflow,
            onActivePaneChanged: observers.onActivePaneChanged,
            onSessionChanged: observers.onSessionChanged,
            onTopologyChanged: observers.onTopologyChanged,
            onExit: observers.onExit,
            onConnectionStateChanged: observers.onConnectionStateChanged
        )
    }
}
