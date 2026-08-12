#if ORBIT_SPARKLE
import Foundation
import Sparkle

extension UpdaterController: SPUUpdaterDelegate {

    // Sparkle: an empty set means stable-only, not silence — the default channel is always included.
    @objc(allowedChannelsForUpdater:)
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        isPrereleaseChannelEnabled ? [UpdaterController.prereleaseChannelName] : []
    }
}

#endif
