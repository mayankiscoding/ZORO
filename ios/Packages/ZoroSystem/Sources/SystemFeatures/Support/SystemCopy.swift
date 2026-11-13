import Foundation

/// Reference strings used by more than one screen. Sentence case, plain verbs, no exclamation marks.
public enum SystemCopy {
    public static let notPaired = "This device isn't connected to a ZORO server yet. Open Settings to connect."
    public static let deviceRemoved = "This device was removed from ZORO. Pair it again to continue."
    public static let unreachable = "Can't reach your ZORO server. Check that your Mac is awake and on Tailscale."
    public static let killSwitchOn = "ZORO is paused. Turn it back on in Security and privacy."
    public static let cancelledNothingChanged = "Nothing was changed."
}
