import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Unit coverage for ``RemoteTmuxMultiplexReconciler`` — the pure create/update/remove
/// diff that reconciles a host's per-session mirrors against the shared view
/// connection's published workspaces (multiplexed transport, GA workspace model).
@Suite struct RemoteTmuxMultiplexReconcilerTests {
    private typealias Model = RemoteTmuxLinkedWorkspaceModel
    private typealias R = RemoteTmuxMultiplexReconciler

    private func ws(_ name: String, _ windowIds: [String], active: String? = nil) -> Model.Workspace {
        Model.Workspace(sessionName: name, windowIds: windowIds, activeWindowId: active)
    }

    @Test func parsesNumericWindowIds() {
        #expect(R.numericWindowId("@7") == 7)
        #expect(R.numericWindowId("12") == 12)
        #expect(R.numericWindowId("@notanumber") == nil)
        #expect(R.numericWindowId("") == nil)
    }

    @Test func sessionViewDropsMalformedIds() {
        let view = R.sessionView(ws("work", ["@1", "@bad", "@3"]))
        #expect(view.sessionName == "work")
        #expect(view.windowIds == [1, 3])
    }

    @Test func newSessionsAreCreated() {
        let plan = R.plan(workspaces: [ws("a", ["@1"]), ws("b", ["@2"])], existingSessionNames: [])
        #expect(plan.create.map(\.sessionName) == ["a", "b"])
        #expect(plan.update.isEmpty)
        #expect(plan.remove.isEmpty)
    }

    @Test func existingSessionsAreUpdatedNotRecreated() {
        let plan = R.plan(workspaces: [ws("a", ["@1", "@5"])], existingSessionNames: ["a"])
        #expect(plan.create.isEmpty)
        #expect(plan.update.count == 1)
        #expect(plan.update.first?.windowIds == [1, 5])
        #expect(plan.remove.isEmpty)
    }

    @Test func vanishedSessionsAreRemoved() {
        let plan = R.plan(workspaces: [ws("a", ["@1"])], existingSessionNames: ["a", "b", "c"])
        #expect(plan.create.isEmpty)
        #expect(plan.update.map(\.sessionName) == ["a"])
        #expect(plan.remove == ["b", "c"])   // sorted
    }

    @Test func mixedCreateUpdateRemove() {
        let plan = R.plan(
            workspaces: [ws("keep", ["@1"]), ws("new", ["@2"])],
            existingSessionNames: ["keep", "gone"]
        )
        #expect(plan.create.map(\.sessionName) == ["new"])
        #expect(plan.update.map(\.sessionName) == ["keep"])
        #expect(plan.remove == ["gone"])
    }

    @Test func createUpdateFollowWorkspaceOrder() {
        // Order is preserved from the workspaces list (deterministic side-effect order).
        let plan = R.plan(
            workspaces: [ws("z", ["@1"]), ws("a", ["@2"])],
            existingSessionNames: []
        )
        #expect(plan.create.map(\.sessionName) == ["z", "a"])
    }

    @Test func emptyWorkspacesRemovesEverything() {
        let plan = R.plan(workspaces: [], existingSessionNames: ["a", "b"])
        #expect(plan.create.isEmpty)
        #expect(plan.update.isEmpty)
        #expect(plan.remove == ["a", "b"])
    }
}
