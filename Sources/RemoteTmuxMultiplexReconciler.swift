import Foundation

/// Pure diff that turns the shared view connection's published workspaces into the
/// create / update / remove actions the controller applies to its per-session
/// mirrors, when a host's sessions are multiplexed over one `tmux -CC` stream.
///
/// Keyed by session name — the GA workspace identity — so a multiplexed host uses
/// the exact same one-workspace-per-session model as a dedicated-connection host.
/// (A session RENAME therefore reads as remove-old + create-new here; matching GA's
/// live re-key is a coordinator follow-up, tracked with the channel's rename no-op.)
///
/// Pure (no tmux, no I/O) so the reconcile policy is deterministic and unit-testable;
/// the controller performs the resulting side effects (channel + workspace + mirror).
enum RemoteTmuxMultiplexReconciler {
    /// One session's scoped window set, ready to drive a channel + mirror. Window ids
    /// are the numeric form the control connection keys `windowsByID` on.
    struct SessionView: Equatable {
        let sessionName: String
        let windowIds: Set<Int>
        let activeWindowId: Int?
    }

    struct Plan: Equatable {
        /// Sessions with no mirror yet — create a channel + workspace + mirror.
        var create: [SessionView]
        /// Sessions that already have a mirror — rescope its channel's window set.
        var update: [SessionView]
        /// Session names whose mirror should be torn down (session gone from the host).
        var remove: [String]
    }

    /// Parses a tmux `@N` window id to its numeric form (the id space the control
    /// connection keys `windowsByID`/`windowOrder` on). Returns nil for a malformed id.
    static func numericWindowId(_ id: String) -> Int? {
        Int(id.hasPrefix("@") ? id.dropFirst() : Substring(id))
    }

    /// Projects a published workspace to a numeric-id `SessionView` (dropping any
    /// malformed window id rather than failing the whole session).
    static func sessionView(_ ws: RemoteTmuxLinkedWorkspaceModel.Workspace) -> SessionView {
        SessionView(
            sessionName: ws.sessionName,
            windowIds: Set(ws.windowIds.compactMap(numericWindowId)),
            activeWindowId: ws.activeWindowId.flatMap(numericWindowId)
        )
    }

    /// Diffs the published `workspaces` against the sessions that already have a live
    /// mirror, in stable order (create/update follow `workspaces`; remove is sorted).
    static func plan(
        workspaces: [RemoteTmuxLinkedWorkspaceModel.Workspace],
        existingSessionNames: Set<String>
    ) -> Plan {
        var create: [SessionView] = []
        var update: [SessionView] = []
        for ws in workspaces {
            let view = sessionView(ws)
            if existingSessionNames.contains(ws.sessionName) {
                update.append(view)
            } else {
                create.append(view)
            }
        }
        let desired = Set(workspaces.map(\.sessionName))
        let remove = existingSessionNames.subtracting(desired).sorted()
        return Plan(create: create, update: update, remove: remove)
    }
}
