import Foundation

/// Resolves which `ActiveStyle` shapes a given dictation, from the frontmost app,
/// the user's default selection, and the stored styles. Pure and AppKit-free so
/// it's unit-testable; the caller (`AppDelegate.endRecording`) supplies the
/// frontmost bundle ID.
///
/// Precedence: a **per-app match wins** (the first stored style whose
/// `activationApps` contains the frontmost bundle ID), otherwise the user's
/// **default** `activeStyleID` — which may itself be Off, Default clean-up, or a
/// style's UUID. An `activeStyleID` that no longer resolves to a stored style
/// (deleted) falls back to Default clean-up, so a dangling default never silently
/// disables cleanup.
enum StyleResolver {

    static func resolve(frontmostBundleID: String?,
                        activeStyleID: String,
                        styles: [Style]) -> ActiveStyle {
        // Per-app override first.
        if let bundleID = frontmostBundleID, !bundleID.isEmpty,
           let match = styles.first(where: { $0.activationApps.contains(bundleID) }) {
            return .custom(match)
        }
        // Otherwise the user's default selection.
        return active(for: activeStyleID, styles: styles)
    }

    /// Map a stored `activeStyleID` string onto an `ActiveStyle`. Unknown ids
    /// (e.g. a deleted style) resolve to Default clean-up.
    static func active(for id: String, styles: [Style]) -> ActiveStyle {
        switch id {
        case ActiveStyle.offID:
            return .off
        case ActiveStyle.defaultCleanupID:
            return .defaultCleanup
        default:
            if let uuid = UUID(uuidString: id), let s = styles.first(where: { $0.id == uuid }) {
                return .custom(s)
            }
            return .defaultCleanup
        }
    }
}
