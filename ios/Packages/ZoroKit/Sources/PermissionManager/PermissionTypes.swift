import Foundation
import ZoroCore

/// Every system permission ZORO may ask for. Asked in context, the first time a feature needs it.
public enum PermissionKind: String, Sendable, CaseIterable, Hashable, Codable {
    case microphone
    case speechRecognition = "speech_recognition"
    case photos
    case health
    case contacts
    case calendars
    case reminders
    case notifications
    case location
    case music
    case alarms
}

/// Normalised authorisation state, the same vocabulary for every framework.
public enum PermissionStatus: String, Sendable, CaseIterable, Hashable, Codable {
    case notDetermined = "not_determined"
    /// Full access (for HealthKit: the sheet was answered; HealthKit never reveals read access).
    case granted
    /// Partial access: limited Photos library, limited Contacts, write-only Calendar, provisional notifications.
    case limited
    /// The owner said no. Only Settings can change it.
    case denied
    /// Blocked by parental controls or a device management profile.
    case restricted
    /// This device, OS version or platform has no such permission or feature.
    case unsupported

    /// Whether the feature can run now (full or limited access).
    public var allowsUse: Bool { self == .granted || self == .limited }
    /// Whether the system sheet can still be shown.
    public var canRequest: Bool { self == .notDetermined }
    /// Whether the owner has to go to Settings to change the answer.
    public var needsSettings: Bool { self == .denied }
}

public enum PermissionCopyLanguage: String, Sendable, CaseIterable, Hashable {
    case english = "en"
    case hindi = "hi"

    /// "hi" and "hinglish" read the Hindi sentence (Hinglish speakers read Devanagari fine); anything else English.
    public init(code: String?) {
        switch code?.lowercased() {
        case "hi", "hinglish": self = .hindi
        default: self = .english
        }
    }
}

extension PermissionKind {
    /// English name for lists and the Settings deep text.
    public var title: String {
        switch self {
        case .microphone: "Microphone"
        case .speechRecognition: "Speech recognition"
        case .photos: "Photos"
        case .health: "Health"
        case .contacts: "Contacts"
        case .calendars: "Calendar"
        case .reminders: "Reminders"
        case .notifications: "Notifications"
        case .location: "Location"
        case .music: "Music"
        case .alarms: "Alarms and timers"
        }
    }

    public var hindiTitle: String {
        switch self {
        case .microphone: "माइक्रोफ़ोन"
        case .speechRecognition: "स्पीच रिकग्निशन"
        case .photos: "फ़ोटो"
        case .health: "हेल्थ"
        case .contacts: "संपर्क"
        case .calendars: "कैलेंडर"
        case .reminders: "रिमाइंडर"
        case .notifications: "नोटिफ़िकेशन"
        case .location: "लोकेशन"
        case .music: "म्यूज़िक"
        case .alarms: "अलार्म और टाइमर"
        }
    }

    public func title(_ language: PermissionCopyLanguage) -> String {
        language == .hindi ? hindiTitle : title
    }

    /// One plain sentence on what the permission is for, shown before the system sheet.
    public func purpose(_ language: PermissionCopyLanguage) -> String {
        switch language {
        case .english: englishPurpose
        case .hindi: hindiPurpose
        }
    }

    public var englishPurpose: String {
        switch self {
        case .microphone: "ZORO listens through the microphone only while you talk to it."
        case .speechRecognition: "ZORO turns your voice into text on your device so it can understand what you ask."
        case .photos: "ZORO searches your photos on this device to find the ones you describe, and never uploads them."
        case .health: "ZORO reads your steps, workouts, sleep and heart rate from Health to answer fitness questions."
        case .contacts: "ZORO looks up your contacts so it can call or message the right person."
        case .calendars: "ZORO reads and adds calendar events when you ask about your schedule or plans."
        case .reminders: "ZORO adds reminders to the Reminders app when you ask it to remind you."
        case .notifications: "ZORO sends a notification when something you asked for is ready or due."
        case .location: "ZORO uses your location only when you ask for something nearby or for local weather."
        case .music: "ZORO plays and controls music in your Apple Music library when you ask."
        case .alarms: "ZORO sets alarms and timers on this iPhone when you ask for them."
        }
    }

    public var hindiPurpose: String {
        switch self {
        case .microphone: "ZORO माइक्रोफ़ोन से सिर्फ़ तभी सुनता है जब आप उससे बात करते हैं।"
        case .speechRecognition: "ZORO आपकी आवाज़ को इसी डिवाइस पर टेक्स्ट में बदलता है ताकि वह आपकी बात समझ सके।"
        case .photos: "ZORO इसी डिवाइस पर आपकी फ़ोटो खोजकर वही फ़ोटो ढूँढता है जो आप बताते हैं, और उन्हें कभी अपलोड नहीं करता।"
        case .health: "ZORO फ़िटनेस के सवालों के जवाब के लिए हेल्थ से आपके क़दम, वर्कआउट, नींद और दिल की धड़कन पढ़ता है।"
        case .contacts: "ZORO आपके संपर्क देखता है ताकि सही व्यक्ति को कॉल या मैसेज कर सके।"
        case .calendars: "जब आप अपने कार्यक्रम के बारे में पूछते हैं, तब ZORO कैलेंडर पढ़ता है और उसमें इवेंट जोड़ता है।"
        case .reminders: "जब आप याद दिलाने को कहते हैं, तब ZORO रिमाइंडर ऐप में रिमाइंडर जोड़ता है।"
        case .notifications: "जो काम आपने कहा था, उसके तैयार होने या समय आने पर ZORO आपको नोटिफ़िकेशन भेजता है।"
        case .location: "ZORO आपकी लोकेशन सिर्फ़ तब इस्तेमाल करता है जब आप आस-पास की चीज़ या स्थानीय मौसम पूछते हैं।"
        case .music: "जब आप कहते हैं, तब ZORO आपकी Apple Music लाइब्रेरी में संगीत चलाता और नियंत्रित करता है।"
        case .alarms: "जब आप कहते हैं, तब ZORO इस iPhone पर अलार्म और टाइमर लगाता है।"
        }
    }
}

/// How a request ended, with what the UI should do next.
public struct PermissionOutcome: Sendable, Equatable {
    public var kind: PermissionKind
    public var status: PermissionStatus
    /// True when the system sheet was shown by this call.
    public var prompted: Bool
    public init(kind: PermissionKind, status: PermissionStatus, prompted: Bool) {
        self.kind = kind
        self.status = status
        self.prompted = prompted
    }
    public var isUsable: Bool { status.allowsUse }
    /// The owner must change this in Settings (denied earlier).
    public var needsSettings: Bool { status.needsSettings }
}

/// What a screen shows before asking: the purpose sentence and what pressing the button will do.
public struct PermissionPrompt: Sendable, Equatable {
    public enum Action: String, Sendable { case requestAccess = "request_access", openSettings = "open_settings", none }
    public var kind: PermissionKind
    public var status: PermissionStatus
    public var title: String
    public var purpose: String
    public var action: Action
}

/// One system permission behind a small protocol. System implementations call the framework; tests use fakes.
public protocol PermissionProviding: Sendable {
    var kind: PermissionKind { get }
    /// Current state. Never shows a system sheet.
    func status() async -> PermissionStatus
    /// Shows the system sheet when the state is `notDetermined`; otherwise returns the current state.
    func request() async -> PermissionStatus
}
