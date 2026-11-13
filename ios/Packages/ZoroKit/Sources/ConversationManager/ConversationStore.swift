import CryptoKit
import Foundation
import ZoroCore

/// Local conversation history in SQLite. Titles, message bodies and cards are sealed with AES-GCM
/// (256-bit key from `KeyStoring`), each bound to its row id as associated data, so nothing readable
/// is written to disk. The file uses complete data protection where the platform supports it.
public actor ConversationStore {
    public static let defaultKeyName = "conversation-store"

    private let db: SQLiteDatabase
    private let key: SymmetricKey
    public nonisolated let fileURL: URL

    public static func open(at url: URL, keys: any KeyStoring, keyName: String = defaultKeyName) async throws -> ConversationStore {
        let raw = try await keys.symmetricKey(named: keyName)
        guard raw.count == 32 else { throw ZoroError.keyUnavailable("conversation key must be 256 bits") }
        return try ConversationStore(url: url, key: SymmetricKey(data: raw))
    }

    init(url: URL, key: SymmetricKey) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.fileURL = url
        self.key = key
        self.db = try SQLiteDatabase(url: url)
        try db.execute("""
            PRAGMA foreign_keys = ON;
            PRAGMA secure_delete = ON;
            PRAGMA journal_mode = DELETE;
            CREATE TABLE IF NOT EXISTS conversations (
              id TEXT PRIMARY KEY, title BLOB NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS messages (
              id TEXT PRIMARY KEY,
              conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
              role TEXT NOT NULL, body BLOB NOT NULL, language TEXT NOT NULL, created_at REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS messages_by_conversation ON messages(conversation_id, created_at);
            CREATE TABLE IF NOT EXISTS cards (
              message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
              position INTEGER NOT NULL, body BLOB NOT NULL, PRIMARY KEY (message_id, position));
            """)
        Self.protect(url)
    }

    private static func protect(_ url: URL) {
        // iPhone: complete. Mac: until first unlock, so history still opens behind a locked screen.
        #if os(iOS)
        let level = FileProtectionType.complete
        #else
        let level = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try? FileManager.default.setAttributes([.protectionKey: level], ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var u = url
        try? u.setResourceValues(values)
    }

    public func close() { db.close() }

    // MARK: - Sealing

    private struct SealedMessage: Codable {
        var text: String
        var agents: [AgentId]
    }

    private func seal(_ plaintext: Data, aad: String) throws -> Data {
        do {
            guard let combined = try AES.GCM.seal(plaintext, using: key, authenticating: Data(aad.utf8)).combined else {
                throw ZoroError.storage("seal failed")
            }
            return combined
        } catch let e as ZoroError {
            throw e
        } catch {
            throw ZoroError.storage("seal failed")
        }
    }

    private func open(_ sealed: Data, aad: String) throws -> Data {
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: Data(aad.utf8))
        } catch {
            throw ZoroError.storage("a stored record failed authentication")
        }
    }

    private func sealJSON<T: Encodable>(_ value: T, aad: String) throws -> Data {
        try seal(try ZoroJSON.encoder().encode(value), aad: aad)
    }

    private func openJSON<T: Decodable>(_ type: T.Type, _ sealed: Data, aad: String) throws -> T {
        try ZoroJSON.decoder().decode(T.self, from: try open(sealed, aad: aad))
    }

    // MARK: - Writes

    /// Creates or renames a conversation.
    public func saveConversation(id: String, title: String, updatedAt: Date) throws {
        let sealedTitle = try seal(Data(title.utf8), aad: "conversation:\(id)")
        try db.query(
            """
            INSERT INTO conversations (id, title, created_at, updated_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET title = excluded.title, updated_at = MAX(updated_at, excluded.updated_at)
            """,
            [.text(id), .blob(sealedTitle), .double(updatedAt.timeIntervalSince1970), .double(updatedAt.timeIntervalSince1970)])
    }

    /// Stores (or replaces) a message and its cards; creates the conversation when missing.
    public func append(_ message: Message, to conversationId: String, conversationTitle: String? = nil) throws {
        let body = try sealJSON(SealedMessage(text: message.text, agents: message.agents), aad: "message:\(message.id)")
        let sealedCards = try message.cards.enumerated().map { i, card in
            try sealJSON(card, aad: "card:\(message.id):\(i)")
        }
        let defaultTitle = conversationTitle ?? String(message.text.prefix(60))
        let sealedTitle = try seal(Data(defaultTitle.utf8), aad: "conversation:\(conversationId)")
        let at = message.createdAt.timeIntervalSince1970
        try db.transaction {
            try db.query(
                """
                INSERT INTO conversations (id, title, created_at, updated_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET updated_at = MAX(updated_at, excluded.updated_at)
                """, [.text(conversationId), .blob(sealedTitle), .double(at), .double(at)])
            try db.query(
                """
                INSERT INTO messages (id, conversation_id, role, body, language, created_at) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET body = excluded.body, language = excluded.language
                """,
                [.text(message.id), .text(conversationId), .text(message.role.rawValue), .blob(body), .text(message.language), .double(at)])
            try db.query("DELETE FROM cards WHERE message_id = ?", [.text(message.id)])
            for (i, sealed) in sealedCards.enumerated() {
                try db.query("INSERT INTO cards (message_id, position, body) VALUES (?, ?, ?)", [.text(message.id), .int(Int64(i)), .blob(sealed)])
            }
        }
    }

    public func deleteConversation(id: String) throws {
        try db.query("DELETE FROM conversations WHERE id = ?", [.text(id)])
    }

    /// Deletes conversations not updated since `cutoff`. Returns how many were removed.
    @discardableResult
    public func purge(olderThan cutoff: Date) throws -> Int {
        try db.query("DELETE FROM conversations WHERE updated_at < ?", [.double(cutoff.timeIntervalSince1970)])
        return db.changes
    }

    /// Applies the retention setting (`conversation_retention_days`, 30 by default on the server).
    @discardableResult
    public func applyRetention(days: Int, now: Date = Date()) throws -> Int {
        guard days > 0 else { return 0 }
        return try purge(olderThan: now.addingTimeInterval(-Double(days) * 86_400))
    }

    public func deleteAll() throws {
        try db.execute("DELETE FROM conversations; VACUUM;")
    }

    // MARK: - Reads

    public func conversations(limit: Int = 100) throws -> [ConversationSummary] {
        let rows = try db.query(
            """
            SELECT c.id, c.title, c.updated_at, COUNT(m.id),
              (SELECT id FROM messages WHERE conversation_id = c.id ORDER BY created_at DESC, rowid DESC LIMIT 1),
              (SELECT body FROM messages WHERE conversation_id = c.id ORDER BY created_at DESC, rowid DESC LIMIT 1)
            FROM conversations c LEFT JOIN messages m ON m.conversation_id = c.id
            GROUP BY c.id ORDER BY c.updated_at DESC LIMIT ?
            """, [.int(Int64(limit))])
        return try rows.map { row in
            let id = row[0].text ?? ""
            let title = String(decoding: try open(row[1].blob ?? Data(), aad: "conversation:\(id)"), as: UTF8.self)
            var preview = ""
            if let lastId = row[4].text, let body = row[5].blob {
                preview = String(try openJSON(SealedMessage.self, body, aad: "message:\(lastId)").text.prefix(120))
            }
            return ConversationSummary(
                id: id, title: title, updatedAt: Date(timeIntervalSince1970: row[2].double ?? 0), lastMessagePreview: preview,
                messageCount: row[3].int ?? 0)
        }
    }

    public func messages(in conversationId: String) throws -> [Message] {
        let rows = try db.query(
            "SELECT id, role, body, language, created_at FROM messages WHERE conversation_id = ? ORDER BY created_at, rowid",
            [.text(conversationId)])
        return try rows.map { row in
            let id = row[0].text ?? ""
            let sealed = try openJSON(SealedMessage.self, row[2].blob ?? Data(), aad: "message:\(id)")
            let cardRows = try db.query("SELECT position, body FROM cards WHERE message_id = ? ORDER BY position", [.text(id)])
            let cards = try cardRows.map { c in
                try openJSON(UICard.self, c[1].blob ?? Data(), aad: "card:\(id):\(c[0].int ?? 0)")
            }
            return Message(
                id: id, role: MessageRole(rawValue: row[1].text ?? "") ?? .assistant, text: sealed.text,
                language: row[3].text ?? "en", createdAt: Date(timeIntervalSince1970: row[4].double ?? 0),
                agents: sealed.agents, cards: cards)
        }
    }
}
