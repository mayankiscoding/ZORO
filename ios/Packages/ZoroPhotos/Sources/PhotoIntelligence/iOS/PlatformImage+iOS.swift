// UNVERIFIED-ON-HOST
// Not compiled on the macOS host. API checked against Apple's documentation:
// UIImage.cgImage (https://developer.apple.com/documentation/uikit/uiimage/cgimage).
#if os(iOS)
import UIKit

/// PhotoKit delivers `UIImage` on iOS. Images drawn from a CIImage have no CGImage; those are
/// treated as unavailable and the asset is indexed by metadata only.
func platformCGImage(_ image: UIImage) -> CGImage? {
    image.cgImage
}
#endif
