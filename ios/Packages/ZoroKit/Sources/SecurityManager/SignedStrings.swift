import Foundation
import ZoroCore

/// The exact UTF-8 strings the backend verifies. ECDSA P-256 over SHA-256, DER signature, base64.
public enum SignedStrings {
    /// `zoro-auth-v1|{device_id}|{nonce}`
    public static func auth(deviceId: String, nonce: String) -> String {
        "zoro-auth-v1|\(deviceId)|\(nonce)"
    }

    /// `zoro-approval-v1|{approval_id}|{action_digest}|{1 or 0}|{signed_at}`
    public static func approval(approvalId: String, actionDigest: String, approved: Bool, signedAt: Date) -> String {
        "zoro-approval-v1|\(approvalId)|\(actionDigest)|\(approved ? "1" : "0")|\(timestamp(signedAt))"
    }

    /// `zoro-action-v1|{action}|{subject}|{signed_at}`
    public static func action(_ action: String, subject: String, signedAt: Date) -> String {
        "zoro-action-v1|\(action)|\(subject)|\(timestamp(signedAt))"
    }

    /// `yyyy-MM-ddTHH:mm:ssZ` in UTC.
    public static func timestamp(_ date: Date) -> String {
        ZoroJSON.isoSeconds(date)
    }
}
