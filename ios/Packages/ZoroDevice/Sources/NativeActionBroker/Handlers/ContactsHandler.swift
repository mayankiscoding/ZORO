import Foundation
import ZoroCore

public struct ContactMatch: Sendable, Equatable {
    public var contactRef: String
    public var name: String
    public var phones: [String]
    public var emails: [String]
    public init(contactRef: String, name: String, phones: [String], emails: [String]) {
        self.contactRef = contactRef
        self.name = name
        self.phones = phones
        self.emails = emails
    }
}

public struct ContactDraft: Sendable, Equatable {
    public var givenName: String
    public var familyName: String?
    public var phone: String?
    public var email: String?
}

/// Contacts framework, behind a protocol.
public protocol ContactsStoring: Sendable {
    func permission() async -> DevicePermission
    func requestAccess() async throws -> DevicePermission
    func find(_ query: String, limit: Int) async throws -> [ContactMatch]
    func save(_ draft: ContactDraft) async throws -> String
}

/// `device.contacts.find`, `device.contacts.save`.
public struct ContactsHandler: DeviceActionHandler {
    let store: any ContactsStoring
    public init(store: any ContactsStoring) { self.store = store }

    public var tools: [DeviceToolName] { [.contactsFind, .contactsSave] }

    public func prepare(_ tool: DeviceToolName, _ args: ToolArguments) throws -> PreparedDeviceAction {
        let store = self.store
        let gate: @Sendable () async throws -> Void = {
            // Limited access (iOS 18) still lets ZORO read and add the contacts the owner shared.
            try await PermissionGate.ensure(
                "Contacts", allowLimited: true, status: { await store.permission() },
                request: { try await store.requestAccess() })
        }
        switch tool {
        case .contactsFind:
            let query = try args.requiredString("query", maxLength: 200)
            return PreparedDeviceAction(summary: "Look up “\(query)” in your contacts.") {
                try await gate()
                let matches = try await store.find(query, limit: 10)
                return [
                    "matches": .array(matches.prefix(10).map {
                        .object([
                            "contact_ref": .string($0.contactRef), "name": .string($0.name),
                            "phones": .array($0.phones.map(JSONValue.string)),
                            "emails": .array($0.emails.map(JSONValue.string)),
                        ])
                    })
                ]
            }
        case .contactsSave:
            let phone = try args.string("phone", maxLength: 40)
            if let phone, PhoneNumber.digits(phone) == nil {
                throw DeviceActionError.invalidArgument("phone", "is not a phone number")
            }
            let email = try args.string("email", maxLength: 254)
            if let email, !Self.looksLikeEmail(email) {
                throw DeviceActionError.invalidArgument("email", "is not an email address")
            }
            let draft = ContactDraft(
                givenName: try args.requiredString("given_name", maxLength: 100),
                familyName: try args.string("family_name", maxLength: 100), phone: phone, email: email)
            let name = [draft.givenName, draft.familyName].compactMap { $0 }.joined(separator: " ")
            return PreparedDeviceAction(summary: "Save \(name) to your contacts.") {
                try await gate()
                return ["contact_ref": .string(try await store.save(draft))]
            }
        default:
            throw DeviceActionError.unsupported("\(tool.rawValue) is not a contacts tool.")
        }
    }

    static func looksLikeEmail(_ s: String) -> Bool {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !s.contains(" ")
            && !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".")
    }
}

/// Phone number normalisation shared by contacts, WhatsApp and Messages.
public enum PhoneNumber {
    /// International digits only (no `+`), 7 to 15 digits (E.164), or nil when the input is not a number.
    /// Accepts spaces, dashes, dots, parentheses and one leading `+` or `00`.
    public static func digits(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("+") { s.removeFirst() } else if s.hasPrefix("00") { s.removeFirst(2) }
        var out = ""
        for ch in s {
            if ch.isASCII, ch.isNumber { out.append(ch) } else if " -.()".contains(ch) { continue } else { return nil }
        }
        return (7...15).contains(out.count) ? out : nil
    }
}
