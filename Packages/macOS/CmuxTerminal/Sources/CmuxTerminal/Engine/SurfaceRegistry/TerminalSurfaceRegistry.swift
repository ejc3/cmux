public import CmuxTerminalCore
public import Foundation
public import GhosttyKit

/// The process-wide registry of live terminal surfaces and the runtime
/// surface pointers they own.
///
/// Replaces the legacy `static let shared` singleton: the engine owner
/// constructs one registry and injects it; the app delegate attaches itself
/// as the ``MainWindowRouteRetiring`` collaborator at composition time,
/// inverting the legacy `AppDelegate.shared` reach-up.
///
/// Isolation design: the blueprint sketched a repository actor, but the
/// surface model unregisters itself from `deinit` (nonisolated, cannot await)
/// and the runtime-pointer guards run synchronously on paths that touch the
/// native `ghostty_surface_t`. The tables therefore stay behind one lock (the
/// sanctioned shape for state shared with synchronous callers), preserving
/// the legacy call contract exactly; only the route-retire notification hops
/// to the main actor, as it always did.
public final class TerminalSurfaceRegistry: TerminalSurfaceRegistering, Sendable {
    private let lock = NSLock()
    // SAFETY: all five are guarded by `lock`; callers arrive on the main
    // actor and from nonisolated `deinit` paths.
    nonisolated(unsafe) private let surfaces = NSHashTable<AnyObject>.weakObjects()
    nonisolated(unsafe) private var runtimeSurfaceOwners: [UInt: UUID] = [:]
    nonisolated(unsafe) private var surfaceFocusPlacements: [UUID: TerminalSurfaceFocusPlacement] = [:]
    // SAFETY: every read and write is guarded by `lock`.
    nonisolated(unsafe) private var generation: UInt64 = 0
    /// Resolves the collaborator to notify when a surface unregisters.
    ///
    /// Deliberately a resolver rather than a stored reference. The retirer is the app delegate,
    /// and the delegate installs itself here while it is being constructed, so a stored reference
    /// records whichever delegate was built last. Any code that constructs a second delegate --
    /// which tests do -- therefore replaced the live delegate's slot permanently, and because the
    /// reference was weak it went nil for the rest of the process once that temporary was
    /// released. Recoverable main-window routes then stopped being swept, silently. Resolving on
    /// use asks who the delegate is now instead of remembering who it was.
    nonisolated(unsafe) private var routeRetirerResolver: (@MainActor () -> (any MainWindowRouteRetiring)?)?

    /// Creates an empty registry.
    public init() {}

    /// Monotonically increasing revision of surface registrations and removals.
    public var topologyGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    /// Installs how to find the collaborator notified when a surface unregisters, so recoverable
    /// main-window routes without surfaces can be retired.
    ///
    /// Pass a resolver that reads the current delegate, not a captured instance, so constructing
    /// another delegate cannot orphan the sweep. Installing again replaces the resolver, which is
    /// harmless when every caller resolves the same way.
    public func attachRouteRetirerResolver(
        _ resolve: @escaping @MainActor () -> (any MainWindowRouteRetiring)?
    ) {
        lock.lock()
        self.routeRetirerResolver = resolve
        lock.unlock()
    }

    /// Registers a live surface and records its focus placement.
    public func register(_ surface: any TerminalSurfacing) {
        lock.lock()
        defer { lock.unlock() }
        surfaces.add(surface)
        surfaceFocusPlacements[surface.id] = surface.focusPlacement
        generation &+= 1
    }

    /// Removes a surface; drops its focus placement when no other surface
    /// shares the same id, then asks the route retirer to sweep recoverable
    /// main-window routes.
    public func unregister(_ surface: any TerminalSurfacing) {
        lock.lock()
        let surfaceId = surface.id
        surfaces.remove(surface)
        let stillRegistered = surfaces.allObjects
            .compactMap { $0 as? any TerminalSurfacing }
            .contains { $0 !== surface && $0.id == surfaceId }
        if !stillRegistered {
            surfaceFocusPlacements.removeValue(forKey: surfaceId)
        }
        generation &+= 1
        let resolveRouteRetirer = routeRetirerResolver
        lock.unlock()

        Task { @MainActor in
            // Resolve here rather than above: the answer is only meaningful on the main actor, and
            // taking it at use time is what makes a later delegate swap harmless.
            resolveRouteRetirer?()?.retireRecoverableMainWindowRoutesWithoutRegisteredTerminalSurfaces(
                reason: "terminalSurface.unregister"
            )
        }
    }

    /// Records `ownerId` as the owner of a live runtime surface pointer.
    public func registerRuntimeSurface(_ surface: ghostty_surface_t, ownerId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        runtimeSurfaceOwners[UInt(bitPattern: surface)] = ownerId
    }

    /// Clears the owner record, but only while `ownerId` still owns it.
    public func unregisterRuntimeSurface(_ surface: ghostty_surface_t, ownerId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        let key = UInt(bitPattern: surface)
        guard runtimeSurfaceOwners[key] == ownerId else { return }
        runtimeSurfaceOwners.removeValue(forKey: key)
    }

    /// The recorded owner of a runtime surface pointer, if any.
    public func runtimeSurfaceOwnerId(_ surface: ghostty_surface_t) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return runtimeSurfaceOwners[UInt(bitPattern: surface)]
    }

    /// The registered surface with the given id, if it is still alive.
    public func surface(id: UUID) -> (any TerminalSurfacing)? {
        lock.lock()
        let object = surfaces.allObjects
            .compactMap { $0 as? any TerminalSurfacing }
            .first { $0.id == id }
        lock.unlock()
        return object
    }

    /// Whether the surface with the given id is placed in the right-sidebar
    /// dock.
    public func isRightSidebarDockSurface(id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return surfaceFocusPlacements[id] == .rightSidebarDock
    }

    /// Re-records the focus placement for a live surface that moved between the
    /// workspace area and the right-sidebar dock. No-op when the id is not
    /// currently registered, so a stale move cannot resurrect a dropped entry.
    public func updateFocusPlacement(id: UUID, _ placement: TerminalSurfaceFocusPlacement) {
        lock.lock()
        defer { lock.unlock() }
        guard surfaceFocusPlacements[id] != nil else { return }
        surfaceFocusPlacements[id] = placement
    }

    /// A bounded count snapshot for leak diagnostics and crash/app-hang telemetry.
    public func diagnosticSnapshot() -> TerminalSurfaceRegistryDiagnosticSnapshot {
        lock.lock()
        let objects = surfaces.allObjects.compactMap { $0 as? any TerminalSurfacing }
        let runtimeSurfaceCount = runtimeSurfaceOwners.count
        var workspaceSurfaceCount = 0
        var rightSidebarDockSurfaceCount = 0
        for object in objects {
            switch surfaceFocusPlacements[object.id] {
            case .workspace:
                workspaceSurfaceCount += 1
            case .rightSidebarDock:
                rightSidebarDockSurfaceCount += 1
            case .none:
                break
            }
        }
        lock.unlock()

        return TerminalSurfaceRegistryDiagnosticSnapshot(
            registeredSurfaceCount: objects.count,
            workspaceSurfaceCount: workspaceSurfaceCount,
            rightSidebarDockSurfaceCount: rightSidebarDockSurfaceCount,
            runtimeSurfaceCount: runtimeSurfaceCount
        )
    }

    /// All live registered surfaces, ordered by id for stable iteration.
    public func allSurfaces() -> [any TerminalSurfacing] {
        lock.lock()
        let objects = surfaces.allObjects.compactMap { $0 as? any TerminalSurfacing }
        lock.unlock()
        return objects.sorted { lhs, rhs in
            lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
