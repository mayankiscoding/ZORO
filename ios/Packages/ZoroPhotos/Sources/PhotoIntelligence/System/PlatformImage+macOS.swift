#if os(macOS)
import AppKit

/// PhotoKit delivers `NSImage` on macOS.
func platformCGImage(_ image: NSImage) -> CGImage? {
    image.cgImage(forProposedRect: nil, context: nil, hints: nil)
}
#endif
