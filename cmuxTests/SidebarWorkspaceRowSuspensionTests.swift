import AppKit
import CmuxSettings
import CmuxSidebar
import CmuxWorkspaces
import Testing
@testable import cmux_DEV

@Suite
@MainActor
struct SidebarWorkspaceRowSuspensionTests {
    private static func makeSnapshot(
        customDescription: String? = nil,
        manualTaskStatus: WorkspaceTaskStatus? = nil,
        checklistItems: [WorkspaceChecklistItem] = []
    ) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        SidebarWorkspaceSnapshotBuilder.Snapshot(
            presentationKey: SidebarWorkspaceSnapshotFactory.presentationKey(
                settings: SidebarTabItemSettingsSnapshot(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                showsAgentActivity: false
            ),
            title: "Workspace",
            customDescription: customDescription,
            isPinned: false,
            isMuted: false,
            customColorHex: nil, cloudWorkspaceLabel: nil,
            remoteWorkspaceSidebarText: nil,
            remoteConnectionStatusText: "",
            remoteStateHelpText: "",
            showsRemoteReconnectAffordance: false,
            copyableSidebarSSHError: nil,
            latestConversationMessage: nil,
            metadataEntries: [],
            metadataBlocks: [],
            latestLog: nil,
            progress: nil,
            activeCodingAgentCount: 0,
            compactGitBranchSummaryText: nil,
            compactDirectoryCandidates: [],
            compactBranchDirectoryCandidates: [],
            branchDirectoryLines: [],
            branchLinesContainBranch: false,
            pullRequestRows: [],
            listeningPorts: [],
            finderDirectoryPath: nil,
            mediaActivity: BrowserMediaActivity(),
            taskStatus: manualTaskStatus,
            todoStatusMenuModel: manualTaskStatus.map {
                SidebarWorkspaceCompactStatusMenuModel(
                    inferred: $0,
                    activeOverride: $0
                )
            },
            hasManualTaskStatus: manualTaskStatus != nil,
            checklistItems: checklistItems,
            checklistCompletedCount: checklistItems.filter { $0.state == .completed }.count,
            checklistTotalCount: checklistItems.count,
            checklistFirstUncheckedText: checklistItems.first { $0.state != .completed }?.text
        )
    }

    static func makeModel(
        customDescription: String? = nil,
        checklistAddFieldActivationToken: Int = 0,
        manualTaskStatus: WorkspaceTaskStatus? = nil,
        checklistItems: [WorkspaceChecklistItem] = [],
        isChecklistExpanded: Bool = false,
        editingChecklistItemId: UUID? = nil,
        isChecklistPopoverPresented: Bool = false,
        checklistStyle: WorkspaceTodoChecklistStyle? = nil,
        workspaceId: UUID = UUID()
    ) -> SidebarWorkspaceRowModel {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        if let checklistStyle {
            defaults.set(
                checklistStyle.rawValue,
                forKey: BetaFeaturesCatalogSection().workspaceTodosChecklistStyle.userDefaultsKey
            )
        }
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        return SidebarWorkspaceRowModel(
            workspaceId: workspaceId,
            index: 0,
            snapshot: makeSnapshot(
                customDescription: customDescription,
                manualTaskStatus: manualTaskStatus,
                checklistItems: checklistItems
            ),
            settings: settings,
            isActive: false,
            isMultiSelected: false,
            hasUserCustomTitle: false,
            canCloseWorkspace: true,
            accessibilityWorkspaceCount: 1,
            unreadCount: 0,
            latestNotificationText: nil,
            showsAgentActivity: settings.details.showAgentActivity,
            rowSpacing: 8,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            isGrouped: false,
            isFirstRow: true,
            shortcutHintText: nil,
            showsShortcutHints: false,
            colorSchemeIsDark: true,
            globalFontMagnificationPercent: 100,
            isChecklistExpanded: isChecklistExpanded,
            checklistAddFieldActivationToken: checklistAddFieldActivationToken,
            isChecklistPopoverPresented: isChecklistPopoverPresented,
            editingChecklistItemId: editingChecklistItemId,
            todoControlsEnabled: checklistAddFieldActivationToken > 0
                || manualTaskStatus != nil
                || !checklistItems.isEmpty,
            isMetadataExpanded: false,
            isMarkdownExpanded: false
        )
    }

    static func makeActions(
        model: SidebarWorkspaceRowModel,
        workspace: Workspace? = nil,
        tabManager: TabManager? = nil,
        onCommitRename: @escaping (String) -> Void = { _ in },
        onConsumeChecklistAddFieldActivation: @escaping () -> Void = {},
        onChecklistAddItem: @escaping (String) -> Void = { _ in },
        onChecklistEditItem: @escaping (UUID, String) -> Void = { _, _ in },
        onEndChecklistItemEdit: @escaping (UUID) -> Void = { _ in },
        onChecklistPopoverPresentedChange: @escaping (Bool) -> Void = { _ in }
    ) -> SidebarAppKitRowActions {
        let workspace = workspace ?? Workspace()
        let commands = SidebarWorkspaceRowCommands(
            tab: workspace,
            tabManager: tabManager,
            notificationStore: nil,
            index: model.index,
            contextMenuWorkspaceIds: [model.workspaceId],
            remoteContextMenuWorkspaceIds: [],
            allRemoteContextMenuTargetsConnecting: false,
            allRemoteContextMenuTargetsDisconnected: false,
            contextMenuPinState: nil,
            workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot(items: []),
            colorScheme: model.colorSchemeIsDark ? .dark : .light,
            refreshSnapshot: {},
            readSelectedTabIds: { [] },
            writeSelectedTabIds: { _ in },
            readLastSelectionIndex: { nil },
            writeLastSelectionIndex: { _ in },
            setSelectionToTabs: {},
            snapshotProvider: { nil }
        )
        return SidebarAppKitRowActions(
            commands: commands,
            onOpenStatusURL: { _ in },
            onOpenWorkspaceDescriptionURL: { _ in },
            onOpenPullRequest: { _ in },
            onOpenPort: { _ in },
            onToggleChecklistExpansion: {},
            onToggleMetadataExpansion: {},
            onToggleMarkdownExpansion: {},
            onConsumeChecklistAddFieldActivation: onConsumeChecklistAddFieldActivation,
            checklistSetItemState: { _, _ in },
            checklistRemoveItem: { _ in },
            checklistAddItem: onChecklistAddItem,
            checklistEditItem: onChecklistEditItem,
            checklistMoveItem: { _, _ in },
            checklistOpenPane: {},
            checklistAddAttachments: { _ in },
            checklistRemoveAttachment: { _, _ in },
            checklistOpenAttachments: { _, _ in },
            onChecklistPopoverPresentedChange: onChecklistPopoverPresentedChange,
            onBeginChecklistItemEdit: { _ in },
            onEndChecklistItemEdit: onEndChecklistItemEdit,
            applyTodoStatus: { _ in },
            hideTodoStatus: {},
            commitRename: onCommitRename
        )
    }

    @Test
    func suspendedCellReleasesWorkspaceOwnedByItsActions() async {
        let model = Self.makeModel()
        let cell = SidebarWorkspaceRowTableCellView()
        weak var retainedWorkspace: Workspace?
        weak var controlWorkspace: Workspace?
        do {
            let workspace = Workspace()
            retainedWorkspace = workspace
            cell.configure(
                model: model,
                actions: Self.makeActions(model: model, workspace: workspace),
                isPointerHovering: false,
                contextMenuDidOpen: {},
                contextMenuDidClose: {}
            )
            workspace.teardownAllPanels()
            // A workspace outlives its last reference until its torn-down panels finish their
            // main-queue work. The control goes through the same teardown with nothing holding it,
            // so once it is gone, only the cell's actions can still hold the workspace.
            let control = Workspace()
            controlWorkspace = control
            control.teardownAllPanels()
        }

        #expect(await Self.mainQueueSettles { controlWorkspace == nil })
        #expect(retainedWorkspace != nil)
        cell.suspendPresentation()
        #expect(await Self.mainQueueSettles { retainedWorkspace == nil })
    }

    @Test
    func suspensionCommitsInlineRenameBeforeReleasingActions() throws {
        let model = Self.makeModel()
        let cell = SidebarWorkspaceRowTableCellView()
        var committedTitle: String?
        cell.configure(
            model: model,
            actions: Self.makeActions(model: model, onCommitRename: { committedTitle = $0 }),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        cell.beginInlineRename()
        let field = try #require(
            Self.descendants(of: cell).compactMap { $0 as? SidebarInlineRenameTextField }.first
        )
        field.stringValue = "Renamed while closing"

        cell.suspendPresentation(commitEdits: true)

        #expect(committedTitle == "Renamed while closing")
        #expect(field.superview == nil)
        #expect(!cell.isEditing)
    }

    @Test
    func configureReappliesUnchangedModelAfterSuspension() {
        let model = Self.makeModel()
        let cell = SidebarWorkspaceRowTableCellView()
        cell.configure(
            model: model,
            actions: Self.makeActions(model: model),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        var applies = 0
        cell.applyModelProbeForTesting = { _ in applies += 1 }
        cell.suspendPresentation()
        cell.configure(
            model: model,
            actions: Self.makeActions(model: model),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        #expect(applies == 1)
    }

    @Test
    func suspensionClosesVisibleStatusPopover() throws {
        let application = NSApplication.shared
        let model = Self.makeModel(manualTaskStatus: .working)
        let cell = SidebarWorkspaceRowTableCellView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 80)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = cell
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        cell.configure(
            model: model,
            actions: Self.makeActions(model: model),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        _ = cell.layoutContent(model: model, width: cell.bounds.width, apply: true)
        window.contentView?.layoutSubtreeIfNeeded()
        let glyph = try #require(
            Self.descendants(of: cell)
                .compactMap { $0 as? SidebarRowTaskStatusGlyphButton }
                .first { !$0.isHidden }
        )
        let existingWindowIds = Set(application.windows.map(ObjectIdentifier.init))

        #expect(glyph.accessibilityPerformPress())
        let popoverWindow = try #require(
            application.windows.first {
                !existingWindowIds.contains(ObjectIdentifier($0)) && $0.isVisible
            }
        )

        cell.suspendPresentation()

        #expect(!popoverWindow.isVisible)
    }

    @Test
    func transientWindowReparentingPreservesChecklistPopover() throws {
        let application = NSApplication.shared
        let model = Self.makeModel(
            checklistAddFieldActivationToken: 1,
            checklistItems: [WorkspaceChecklistItem(text: "Draft item")],
            isChecklistPopoverPresented: true,
            checklistStyle: .popover
        )
        var presentationChanges: [Bool] = []
        var tokenConsumptions = 0
        let cell = SidebarWorkspaceRowTableCellView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 100)
        )
        let window = NSWindow(
            contentRect: cell.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = cell
        window.orderFront(nil)
        defer { window.close() }
        let existingWindowIds = Set(application.windows.map(ObjectIdentifier.init))
        cell.configure(
            model: model,
            actions: Self.makeActions(
                model: model,
                onConsumeChecklistAddFieldActivation: { tokenConsumptions += 1 },
                onChecklistPopoverPresentedChange: { presentationChanges.append($0) }
            ),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        _ = cell.layoutContent(model: model, width: cell.bounds.width, apply: true)
        cell.layoutSubtreeIfNeeded()
        let popoverWindow = try #require(
            application.windows.first {
                !existingWindowIds.contains(ObjectIdentifier($0)) && $0.isVisible
            }
        )

        #expect(popoverWindow.isVisible)
        var popoverCloseCount = 0
        let closeObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification, object: nil, queue: nil
        ) { _ in popoverCloseCount += 1 }
        defer { NotificationCenter.default.removeObserver(closeObserver) }

        let replacementRoot = NSView(frame: cell.frame)
        window.contentView = replacementRoot
        replacementRoot.addSubview(cell)

        // AppKit closes a transient popover whose anchor leaves its window. Wait for that close to
        // finish, so a dismissal write-back it would trigger has already happened by the checks below.
        let closeDeadline = Date().addingTimeInterval(2)
        while popoverCloseCount == 0, Date() < closeDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        #expect(popoverCloseCount == 1)
        cell.layoutSubtreeIfNeeded()

        #expect(application.windows.contains {
            !existingWindowIds.contains(ObjectIdentifier($0)) && $0.isVisible
        })
        #expect(presentationChanges.isEmpty)
        #expect(tokenConsumptions == 0)
    }

    @Test
    func checklistDraftCommitsOnlyOnceWhenFocusEndsBeforeSuspension() throws {
        let model = Self.makeModel(checklistAddFieldActivationToken: 1, checklistStyle: .inline)
        var additions: [String] = []
        var consumptions = 0
        let cell = SidebarWorkspaceRowTableCellView()
        cell.configure(
            model: model,
            actions: Self.makeActions(
                model: model,
                onConsumeChecklistAddFieldActivation: { consumptions += 1 },
                onChecklistAddItem: { additions.append($0) }
            ),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        let field = try #require(
            Self.descendants(of: cell)
                .compactMap { $0 as? SidebarRowChecklistFocusField }
                .first { !$0.isHidden }
        )
        field.stringValue = "Review checklist lifecycle"
        (field.delegate as? SidebarRowChecklistFieldBridge)?.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: field)
        )
        cell.suspendPresentation(commitEdits: true)
        #expect(additions == ["Review checklist lifecycle"])
        #expect(consumptions == 1)
    }

    @Test
    func switchingChecklistEditorsCommitsPreviousDraft() throws {
        let firstItem = WorkspaceChecklistItem(text: "First")
        let secondItem = WorkspaceChecklistItem(text: "Second")
        let workspaceId = UUID()
        let firstModel = Self.makeModel(
            checklistItems: [firstItem, secondItem], isChecklistExpanded: true,
            editingChecklistItemId: firstItem.id, checklistStyle: .inline, workspaceId: workspaceId
        )
        let secondModel = Self.makeModel(
            checklistItems: [firstItem, secondItem], isChecklistExpanded: true,
            editingChecklistItemId: secondItem.id, checklistStyle: .inline, workspaceId: workspaceId
        )
        var edits: [(UUID, String)] = []
        let actions = Self.makeActions(
            model: firstModel,
            onChecklistEditItem: { edits.append(($0, $1)) }
        )
        let cell = SidebarWorkspaceRowTableCellView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        let window = NSWindow(contentRect: cell.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = cell
        defer { window.close() }
        cell.configure(
            model: firstModel, actions: actions, isPointerHovering: false,
            contextMenuDidOpen: {}, contextMenuDidClose: {}
        )
        let field = try #require(
            Self.descendants(of: cell)
                .compactMap { $0 as? SidebarRowChecklistFocusField }
                .first { $0.accessibilityIdentifier() == "SidebarChecklistEditItemField" }
        )
        field.stringValue = "  Updated first item  "

        cell.configure(
            model: secondModel, actions: actions, isPointerHovering: false,
            contextMenuDidOpen: {}, contextMenuDidClose: {}
        )

        #expect(edits.count == 1)
        #expect(edits.first?.0 == firstItem.id)
        #expect(edits.first?.1 == "Updated first item")
    }

    @Test
    func checklistItemDraftCommitDefersUntilAfterDetachment() throws {
        let item = WorkspaceChecklistItem(text: "Original checklist item")
        let model = Self.makeModel(
            checklistItems: [item],
            isChecklistExpanded: true,
            editingChecklistItemId: item.id,
            checklistStyle: .inline
        )
        var endedItemIds: [UUID] = []
        var edits: [(itemId: UUID, text: String)] = []
        let cell = SidebarWorkspaceRowTableCellView()
        cell.configure(
            model: model,
            actions: Self.makeActions(
                model: model,
                onChecklistEditItem: { edits.append(($0, $1)) },
                onEndChecklistItemEdit: { endedItemIds.append($0) }
            ),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        let field = try #require(
            Self.descendants(of: cell)
                .compactMap { $0 as? SidebarRowChecklistFocusField }
                .first { $0.accessibilityIdentifier() == "SidebarChecklistEditItemField" }
        )
        field.stringValue = "  Updated while closing  "

        let postUpdateActions = cell.detachPresentation(commitEdits: true)

        #expect(endedItemIds.isEmpty)
        #expect(edits.isEmpty)
        for action in postUpdateActions { action() }
        #expect(endedItemIds == [item.id])
        #expect(edits.count == 1)
        #expect(edits.first?.itemId == item.id)
        #expect(edits.first?.text == "Updated while closing")
    }

    @Test
    func emptyChecklistItemDraftCancellationDefersUntilAfterDetachment() throws {
        let item = WorkspaceChecklistItem(text: "Original checklist item")
        let model = Self.makeModel(
            checklistItems: [item],
            isChecklistExpanded: true,
            editingChecklistItemId: item.id,
            checklistStyle: .inline
        )
        var endedItemIds: [UUID] = []
        var edits: [(UUID, String)] = []
        let cell = SidebarWorkspaceRowTableCellView()
        cell.configure(
            model: model,
            actions: Self.makeActions(
                model: model,
                onChecklistEditItem: { edits.append(($0, $1)) },
                onEndChecklistItemEdit: { endedItemIds.append($0) }
            ),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        let field = try #require(
            Self.descendants(of: cell)
                .compactMap { $0 as? SidebarRowChecklistFocusField }
                .first { $0.accessibilityIdentifier() == "SidebarChecklistEditItemField" }
        )
        field.stringValue = "   "

        let postUpdateActions = cell.detachPresentation(commitEdits: true)

        #expect(endedItemIds.isEmpty)
        for action in postUpdateActions { action() }
        #expect(endedItemIds == [item.id])
        #expect(edits.isEmpty)
    }

    /// Runs main-queue turns until `condition` holds, for at most `maxTurns` turns.
    private static func mainQueueSettles(maxTurns: Int = 200, _ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< maxTurns {
            if condition() { return true }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        return condition()
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
