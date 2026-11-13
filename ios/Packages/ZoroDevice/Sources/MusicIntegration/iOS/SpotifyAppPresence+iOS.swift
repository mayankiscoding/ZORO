// UNVERIFIED-ON-HOST
// UIApplication.canOpenURL(_:) (iOS 3+) needs "spotify" in the app's LSApplicationQueriesSchemes.
#if os(iOS) && canImport(UIKit)
import UIKit

public enum SpotifyAppPresence {
    @MainActor
    public static func isInstalled() -> Bool {
        guard let url = URL(string: "spotify:") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }
}
#endif
