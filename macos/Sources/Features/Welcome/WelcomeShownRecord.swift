import Foundation

/// Whether the welcome window opens by itself, and what it remembers.
///
/// Two facts, kept apart because they answer different questions. The revision
/// is *has this reader been shown the panel* — asked once, answered forever.
/// The switch is *do I want it every time*, which is the reader's, and which
/// nothing here may overwrite.
///
/// **Versioned rather than boolean.** A reader upgrading from an earlier
/// Phantom has never seen this window, and a boolean written by an older build
/// could not tell them apart from somebody who had. The revision also leaves
/// room for a later panel worth showing again, without a second key that would
/// then have to agree with this one.
///
/// **Never keyed on the app's version string.** That shows the panel on every
/// release, which is a newsletter, not a welcome.
enum WelcomeShownRecord {
    static let revisionKey = "WelcomeShownRevision"
    static let showsAtLaunchKey = "WelcomeShowsAtLaunch"

    /// Bumped only when there is something new worth stopping a reader for.
    /// Going up shows the window once more; it has never gone up.
    static let currentRevision = 1

    /// The rule, without `UserDefaults`, so it can be exercised.
    ///
    /// - Parameters:
    ///   - shownRevision: what this reader has already been shown; 0 when the
    ///     key is absent, which is what a first launch looks like.
    ///   - showsAtLaunch: the reader's own switch.
    ///
    /// A revision from a *newer* build reads as already shown. That is the
    /// opposite of what `LanguageTrustStore` does with a record it does not
    /// understand, and correct here for the opposite reason: there, an
    /// unreadable record must not stand in for permission; here, the worst case
    /// is a window nobody asked for.
    static func opensAtLaunch(shownRevision: Int, showsAtLaunch: Bool) -> Bool {
        showsAtLaunch || shownRevision < currentRevision
    }

    static var opensAtLaunch: Bool {
        opensAtLaunch(shownRevision: shownRevision, showsAtLaunch: showsAtLaunch)
    }

    static var shownRevision: Int {
        UserDefaults.standard.integer(forKey: revisionKey)
    }

    /// Absent means off: a window that opened by itself once should not go on
    /// doing it because nobody found the switch.
    static var showsAtLaunch: Bool {
        UserDefaults.standard.bool(forKey: showsAtLaunchKey)
    }

    static func setShowsAtLaunch(_ shows: Bool) {
        UserDefaults.standard.set(shows, forKey: showsAtLaunchKey)
    }

    /// Written when the window is *shown*, not when it is finished.
    ///
    /// Somebody who closes it immediately has been shown it, and asking again
    /// next launch is how a welcome becomes a nag. Everything it offers is in
    /// Settings and under Help, and the panel says so.
    static func markShown() {
        guard shownRevision < currentRevision else { return }
        UserDefaults.standard.set(currentRevision, forKey: revisionKey)
    }
}
