import Foundation
import SecurityManager
import Testing
import ZoroCore
@testable import ConversationManager

func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("zorokit-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("conversations.sqlite")
}

private let t0 = Date(timeIntervalSince1970: 1_794_475_815)

@Suite("Conversation store")
struct ConversationStoreTests {
    @Test func roundTripsMessagesAndCards() async throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let keys = InMemoryKeyStore()
        let store = try await ConversationStore.open(at: url, keys: keys)
        let card = UICard(kind: "finance_summary", title: "October", payload: ["total": "1234.50", "nested": ["a": [1, true]]])
        try await store.append(Message(id: "m1", role: .user, text: "मेरा खर्च कितना हुआ?", language: "hi", createdAt: t0), to: "c1")
        try await store.append(
            Message(id: "m2", role: .assistant, text: "You spent ₹1,234.50.", createdAt: t0.addingTimeInterval(1), agents: [.finance], cards: [card]),
            to: "c1")

        let messages = try await store.messages(in: "c1")
        #expect(messages.map(\.id) == ["m1", "m2"])
        #expect(messages[0].text == "मेरा खर्च कितना हुआ?" && messages[0].language == "hi")
        #expect(messages[1].cards == [card] && messages[1].agents == [.finance])

        let list = try await store.conversations()
        #expect(list.count == 1)
        #expect(list[0].title == "मेरा खर्च कितना हुआ?")
        #expect(list[0].messageCount == 2 && list[0].lastMessagePreview == "You spent ₹1,234.50.")

        // Re-saving the same message id replaces it instead of duplicating it.
        try await store.append(Message(id: "m2", role: .assistant, text: "Updated", createdAt: t0.addingTimeInterval(1)), to: "c1")
        #expect(try await store.messages(in: "c1").map(\.text) == ["मेरा खर्च कितना हुआ?", "Updated"])
        #expect(try await store.messages(in: "c1")[1].cards.isEmpty)

        // Reopening with the same key reads the data back.
        await store.close()
        let reopened = try await ConversationStore.open(at: url, keys: keys)
        #expect(try await reopened.messages(in: "c1").count == 2)
    }

    @Test func plaintextNeverReachesTheDatabaseFile() async throws {
        let url = temporaryDatabaseURL()
        let dir = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await ConversationStore.open(at: url, keys: InMemoryKeyStore())
        let secret = "PAN-ABCDE1234F-salary-98765"
        try await store.saveConversation(id: "c1", title: "Title \(secret)", updatedAt: t0)
        try await store.append(
            Message(id: "m1", role: .user, text: "my \(secret)", createdAt: t0,
                    cards: [UICard(kind: "transactions", payload: ["note": .string(secret)])]),
            to: "c1")
        #expect(try await store.messages(in: "c1").first?.text == "my \(secret)")
        await store.close()

        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(!files.isEmpty)
        for file in files {
            let bytes = try Data(contentsOf: file)
            #expect(bytes.range(of: Data(secret.utf8)) == nil, "plaintext found in \(file.lastPathComponent)")
            #expect(bytes.range(of: Data("salary".utf8)) == nil)
        }
    }

    @Test func wrongKeyCannotReadRecords() async throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try await ConversationStore.open(at: url, keys: InMemoryKeyStore())
        try await store.append(Message(id: "m1", role: .user, text: "hello", createdAt: t0), to: "c1")
        await store.close()
        let intruder = try await ConversationStore.open(at: url, keys: InMemoryKeyStore())
        await #expect(throws: ZoroError.storage("a stored record failed authentication")) { try await intruder.messages(in: "c1") }
    }

    @Test func retentionPurgeAndDeleteCascade() async throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try await ConversationStore.open(at: url, keys: InMemoryKeyStore())
        let now = t0
        try await store.append(Message(id: "old", role: .user, text: "old", createdAt: now.addingTimeInterval(-40 * 86_400)), to: "c-old")
        try await store.append(Message(id: "new", role: .user, text: "new", createdAt: now.addingTimeInterval(-86_400),
                                       cards: [UICard(kind: "memory")]), to: "c-new")
        #expect(try await store.applyRetention(days: 30, now: now) == 1)
        #expect(try await store.conversations().map(\.id) == ["c-new"])
        #expect(try await store.messages(in: "c-old").isEmpty)
        #expect(try await store.applyRetention(days: 0, now: now) == 0)  // 0 = keep

        try await store.deleteConversation(id: "c-new")
        #expect(try await store.conversations().isEmpty)
        #expect(try await store.messages(in: "c-new").isEmpty)
    }

    @Test func badKeyLengthIsRejected() async {
        struct ShortKeys: KeyStoring {
            var protection: KeyProtection { .memory }
            func ensureSigningKeys() async throws {}
            func publicKey(for purpose: DeviceKeyPurpose) async throws -> Data { Data() }
            func sign(_ message: Data, with purpose: DeviceKeyPurpose, reason: String) async throws -> Data { Data() }
            func symmetricKey(named name: String) async throws -> Data { Data(repeating: 1, count: 16) }
            func deleteAllKeys() async throws {}
        }
        await #expect(throws: ZoroError.self) { try await ConversationStore.open(at: temporaryDatabaseURL(), keys: ShortKeys()) }
    }
}
