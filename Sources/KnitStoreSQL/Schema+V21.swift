// v21 lives here so the schema's enum stays inside the lint's length; like every migration it is frozen once committed.

extension Schema {
    /// Schema v21: the capabilities our own last profile carried (``KnitStore/OwnProfile/capabilities``, knit-ios #25), the
    /// copy knit-next keeps as `SettingsStore.ownProfileCapabilities`. Local only. The row already stored records none, so
    /// the first start after the update publishes our profile again as an edit, and its new capabilities outrank every
    /// profile we signed before it.
    static let v21 = [
        "ALTER TABLE own_profile ADD COLUMN capabilities INTEGER"
    ]
}
