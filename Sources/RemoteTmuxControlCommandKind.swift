import Foundation

enum RemoteTmuxControlCommandKind: Equatable {
    case listWindows
    case capturePane(Int)
    case paneState(Int)
    case panePath(Int)
    case paneReflow(Int)
    case paneAltScreen(Int)
    case activityQuery(UUID)
    /// A generic command whose `%begin`/`%end` reply body is returned to the
    /// caller. Used to run one-shot queries (e.g. `list-sessions`,
    /// `list-windows -a`) over the live control stream when a host permits only a
    /// single concurrent connection, so a separate one-shot ssh isn't possible.
    case query(UUID)
    case other
}
