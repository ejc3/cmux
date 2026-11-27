import CmuxRemoteSession
/// A parsed remote-tmux layout awaiting authoritative pane rectangles.
///
/// Tmux publishes pre-title geometry in its layout string when pane headers
/// are enabled, so the connection quarantines this value until `list-panes`
/// supplies the display rectangles that are safe to publish.
struct RemoteTmuxPendingLayout {
    var node: RemoteTmuxLayoutNode
    var visibleNode: RemoteTmuxLayoutNode?
    var zoomed: Bool
    var name: String
    /// Bumped per stored layout so stale rectangle replies can be discarded.
    var generation: Int
    /// Whether a newer layout arrived while a rectangle fetch was in flight.
    var dirty = false
    var inFlight = false
    var retriesRemaining = 1
}

extension RemoteTmuxPendingLayout {
    /// The raw tmux layout this pending tree was parsed from.
    var raw: RemoteTmuxRawWindowLayout {
        RemoteTmuxRawWindowLayout(node: node, visibleNode: visibleNode, zoomed: zoomed)
    }
}

/// A window's layout exactly as tmux reported it, before `list-panes` corrects the pane rects.
///
/// Two equal values describe the same pane geometry, with one exception the connection tracks
/// itself: a `pane-border-status` change moves pane rows without changing the layout string.
struct RemoteTmuxRawWindowLayout: Equatable {
    var node: RemoteTmuxLayoutNode
    var visibleNode: RemoteTmuxLayoutNode?
    var zoomed: Bool
}
