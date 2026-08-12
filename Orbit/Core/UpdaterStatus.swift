import Foundation

enum UpdaterStatus: Equatable {

    case idle

    case checking

    case upToDate

    /// releaseNotesHTML is nil until the notes callback arrives — not an error.
    case updateAvailable(version: String, releaseNotesHTML: String?, isInformationOnly: Bool)

    /// fractionCompleted is nil until the content length is known — draw indeterminate, not 0%.
    case downloading(fractionCompleted: Double?)

    case extracting(fractionCompleted: Double)

    case readyToRelaunch(version: String)

    case error(message: String)
}
