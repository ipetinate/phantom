import Sparkle
import Cocoa

extension UpdateDriver: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else {
            return nil
        }

        // Phantom's own feed, published by phantom-release.yml as an asset of
        // every release. `releases/latest/download/<asset>` is GitHub's stable
        // alias for the newest non-prerelease, so the URL never has to know a
        // version — and the build that reads it can be years old.
        //
        // Both channels resolve to the same feed on purpose. This fork has no
        // tip pipeline: release-tip.yml is upstream's, run against
        // infrastructure this repo cannot reach. Pointing `tip` at a feed that
        // does not exist would make the config value silently broken; pointing
        // it at the one feed that does exist makes it mean what is true, which
        // is "you get what Phantom publishes".
        //
        // Upstream's feeds must never come back here. With the updater live, a
        // Ghostty appcast would offer to install Ghostty over Phantom — the
        // failure `checkForUpdates` used to be stubbed out to prevent.
        switch appDelegate.ghostty.config.autoUpdateChannel {
        case .tip, .stable:
            return "https://github.com/ipetinate/phantom/releases/latest/download/appcast.xml"
        }
    }

    /// Called when an update is scheduled to install silently,
    /// which occurs when `auto-update = download`.
    ///
    /// When `auto-update = check`, Sparkle will call the corresponding
    /// delegate method on the responsible driver instead.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        viewModel.state = .installing(.init(
            appcastItem: item,
            retryTerminatingApplication: immediateInstallHandler
        ))
        AppDelegate.logger.info("Version: \(item.displayVersionString) installed silently, waiting for relaunch...")
        // Even when hasUnobtrusiveTarget is false, we don't show the alert immediately.
        // We wait until the user manually checks for updates or relaunches.
        return true
    }
}
