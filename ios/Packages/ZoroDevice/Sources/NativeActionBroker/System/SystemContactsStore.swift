#if canImport(Contacts)
import Contacts
import Foundation

/// `ContactsStoring` over `CNContactStore`. Fetches run inside this actor, off the main thread.
public actor SystemContactsStore: ContactsStoring {
    private let store = CNContactStore()

    public init() {}

    public func permission() async -> DevicePermission {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        case .limited: return .limited
        @unknown default: return .denied
        }
    }

    public func requestAccess() async throws -> DevicePermission {
        _ = try await CNContactStore().requestAccess(for: .contacts)
        return await permission()
    }

    public func find(_ query: String, limit: Int) async throws -> [ContactMatch] {
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let predicate: NSPredicate
        if let digits = PhoneNumber.digits(query) {
            predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: digits))
        } else {
            predicate = CNContact.predicateForContacts(matchingName: query)
        }
        return try store.unifiedContacts(matching: predicate, keysToFetch: keys).prefix(limit).map { c in
            ContactMatch(
                contactRef: c.identifier, name: CNContactFormatter.string(from: c, style: .fullName) ?? "",
                phones: c.phoneNumbers.map(\.value.stringValue), emails: c.emailAddresses.map { $0.value as String })
        }
    }

    public func save(_ draft: ContactDraft) async throws -> String {
        let contact = CNMutableContact()
        contact.givenName = draft.givenName
        contact.familyName = draft.familyName ?? ""
        if let phone = draft.phone {
            contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone))]
        }
        if let email = draft.email {
            contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: email as NSString)]
        }
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        try store.execute(request)
        return contact.identifier
    }
}
#endif
