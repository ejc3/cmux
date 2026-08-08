import Foundation

/// Settings for mirroring a remote host's tmux (the `remoteTmux.*` keys).
///
/// The beta gate itself lives in ``BetaFeaturesCatalogSection`` under
/// `remoteTmux.beta.enabled`; this section holds configuration that outlives the
/// beta.
public struct RemoteTmuxCatalogSection: SettingCatalogSection {
    /// Host-scoped transport rules — how this machine reaches a host's tmux when the
    /// default does not.
    ///
    /// Empty by default, so a host nobody has configured behaves exactly as before.
    /// See ``RemoteTmuxTransportRule`` for the shape and matching semantics.
    public let transports = JSONKey<[RemoteTmuxTransportRule]>(
        id: "remoteTmux.transports",
        defaultValue: []
    )

    public init() {}
}
