import Foundation
import ZoroCore

/// The private on-device visual index: SQLite (system library) with FTS5 for labels and recognised
/// text. Holds identifiers, metadata and derived features only, never image bytes.
public actor PhotoIndexStore {
    static let schemaVersion = 1
    /// Upper bound of candidates loaded for ranking in one search.
    public static let candidateCap = 5000

    private let db: SQLiteConnection

    /// Opens (or creates) the index file. The file is excluded from device backups: it is derived
    /// data that can be rebuilt on the device, so it never needs to leave it.
    public init(fileURL: URL, protection: IndexFileProtection = .complete) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteConnection(path: fileURL.path, protection: protection)
        try Self.migrate(db)
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// A private in-memory index (tests, previews).
    public init() throws {
        db = try SQLiteConnection(path: nil)
        try Self.migrate(db)
    }

    private static func migrate(_ db: SQLiteConnection) throws {
        try db.execute(
            """
            PRAGMA foreign_keys = ON;
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS assets (
                id INTEGER PRIMARY KEY,
                asset_id TEXT NOT NULL UNIQUE,
                captured_at REAL,
                modified_at REAL,
                media TEXT NOT NULL,
                has_location INTEGER NOT NULL,
                analysis_version INTEGER NOT NULL,
                analysis_complete INTEGER NOT NULL,
                indexed_at REAL NOT NULL,
                feature_print BLOB,
                embedding BLOB,
                embedding_model TEXT
            );
            CREATE INDEX IF NOT EXISTS assets_captured ON assets(captured_at);
            CREATE TABLE IF NOT EXISTS labels (
                asset_rowid INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
                label TEXT NOT NULL,
                confidence REAL NOT NULL,
                PRIMARY KEY (asset_rowid, label)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS labels_label ON labels(label);
            CREATE TABLE IF NOT EXISTS colours (
                asset_rowid INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
                region TEXT NOT NULL,
                colour TEXT NOT NULL,
                fraction REAL NOT NULL,
                PRIMARY KEY (asset_rowid, region, colour)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS colours_colour ON colours(colour);
            CREATE VIRTUAL TABLE IF NOT EXISTS asset_fts USING fts5(labels, body, tokenize = 'unicode61 remove_diacritics 2');
            """)
        try db.query("INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', ?)", [.text(String(schemaVersion))])
    }

    // MARK: - Writing

    /// Inserts or replaces assets in one transaction (one batch of the indexer).
    public func upsert(_ assets: [IndexedAsset]) throws {
        guard !assets.isEmpty else { return }
        try db.transaction {
            for item in assets {
                _ = try deleteRows(assetIds: [item.asset.id])
                let a = item.asset
                try db.query(
                    """
                    INSERT INTO assets (asset_id, captured_at, modified_at, media, has_location, analysis_version,
                        analysis_complete, indexed_at, feature_print, embedding, embedding_model)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(a.id), .optional(a.capturedAt?.timeIntervalSince1970), .optional(a.modifiedAt?.timeIntervalSince1970),
                        .text(a.kind.rawValue), .int(a.hasLocation ? 1 : 0), .int(Int64(item.analysisVersion)),
                        .int(item.analysisComplete ? 1 : 0), .double(item.indexedAt.timeIntervalSince1970),
                        .optional(item.featurePrint.map(VectorMath.encode)), .optional(item.embedding.map(VectorMath.encode)),
                        .optional(item.embeddingModel),
                    ])
                let rowid = db.lastInsertRowID
                var labelNames: [String] = []
                for label in item.labels {
                    let name = TextNormalizer.normalize(label.name)
                    guard !name.isEmpty else { continue }
                    labelNames.append(name)
                    try db.query(
                        "INSERT OR REPLACE INTO labels (asset_rowid, label, confidence) VALUES (?, ?, ?)",
                        [.int(rowid), .text(name), .double(label.confidence)])
                }
                for colour in item.colours {
                    try db.query(
                        "INSERT OR REPLACE INTO colours (asset_rowid, region, colour, fraction) VALUES (?, ?, ?, ?)",
                        [.int(rowid), .text(colour.region.description), .text(colour.colour.rawValue), .double(colour.fraction)])
                }
                try db.query(
                    "INSERT INTO asset_fts (rowid, labels, body) VALUES (?, ?, ?)",
                    [.int(rowid), .text(labelNames.joined(separator: " ; ")), .text(TextNormalizer.normalize(item.text))])
            }
        }
    }

    /// Removes assets and everything derived from them. Returns how many were indexed.
    @discardableResult
    public func delete(assetIds: [String]) throws -> Int {
        guard !assetIds.isEmpty else { return 0 }
        return try db.transaction { try deleteRows(assetIds: assetIds) }
    }

    private func deleteRows(assetIds: [String]) throws -> Int {
        var removed = 0
        for chunk in assetIds.chunked(400) {
            let marks = Self.placeholders(chunk.count)
            let ids = try db.query("SELECT id FROM assets WHERE asset_id IN (\(marks))", chunk.map(SQLiteConnection.Value.text))
                .compactMap { $0[0].int }
            guard !ids.isEmpty else { continue }
            let rowMarks = Self.placeholders(ids.count)
            let rowValues = ids.map(SQLiteConnection.Value.int)
            try db.query("DELETE FROM asset_fts WHERE rowid IN (\(rowMarks))", rowValues)
            try db.query("DELETE FROM labels WHERE asset_rowid IN (\(rowMarks))", rowValues)
            try db.query("DELETE FROM colours WHERE asset_rowid IN (\(rowMarks))", rowValues)
            try db.query("DELETE FROM assets WHERE id IN (\(rowMarks))", rowValues)
            removed += ids.count
        }
        return removed
    }

    /// Deletes the whole index and compacts the file so no derived data stays on disk.
    public func deleteAll() throws {
        try db.transaction {
            try db.execute(
                "DELETE FROM asset_fts; DELETE FROM labels; DELETE FROM colours; DELETE FROM assets; DELETE FROM meta WHERE key <> 'schema_version';")
        }
        try db.execute("INSERT INTO asset_fts(asset_fts) VALUES('optimize'); VACUUM;")
    }

    public func setMeta(_ key: String, _ value: String?) throws {
        if let value {
            try db.query("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [.text(key), .text(value)])
        } else {
            try db.query("DELETE FROM meta WHERE key = ?", [.text(key)])
        }
    }

    public func meta(_ key: String) throws -> String? {
        try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?[0].string
    }

    // MARK: - Reading

    public func fingerprints() throws -> [String: IndexFingerprint] {
        var out = [String: IndexFingerprint]()
        try db.forEachRow("SELECT asset_id, modified_at, analysis_version, analysis_complete FROM assets") { row in
            guard let id = row[0].string else { return }
            out[id] = IndexFingerprint(
                modifiedAt: row[1].double.map(Date.init(timeIntervalSince1970:)),
                analysisVersion: Int(row[2].int ?? 0), analysisComplete: row[3].int == 1)
        }
        return out
    }

    /// Number of indexed assets.
    public func count() throws -> Int {
        Int(try db.query("SELECT COUNT(*) FROM assets").first?[0].int ?? 0)
    }

    /// Row counts of every table (verifies deletion leaves nothing behind).
    public func rowCounts() throws -> [String: Int] {
        var out = [String: Int]()
        for table in ["assets", "labels", "colours", "asset_fts"] {
            out[table] = Int(try db.query("SELECT COUNT(*) FROM \(table)").first?[0].int ?? 0)
        }
        out["meta"] = Int(try db.query("SELECT COUNT(*) FROM meta WHERE key <> 'schema_version'").first?[0].int ?? 0)
        return out
    }

    public func asset(id: String) throws -> IndexedAsset? {
        guard let row = try db.query(
            """
            SELECT a.id, a.asset_id, a.captured_at, a.modified_at, a.media, a.has_location, a.analysis_version,
                a.analysis_complete, a.indexed_at, a.feature_print, a.embedding, a.embedding_model, f.body
            FROM assets a LEFT JOIN asset_fts f ON f.rowid = a.id WHERE a.asset_id = ?
            """, [.text(id)]).first, let rowid = row[0].int
        else { return nil }
        let details = try loadDetails([rowid])
        let library = LibraryAsset(
            id: row[1].string ?? id, capturedAt: row[2].double.map(Date.init(timeIntervalSince1970:)),
            modifiedAt: row[3].double.map(Date.init(timeIntervalSince1970:)),
            kind: PhotoMediaKind(rawValue: row[4].string ?? "") ?? .photo, hasLocation: row[5].int == 1)
        return IndexedAsset(
            asset: library, labels: details.labels[rowid] ?? [], text: row[12].string ?? "",
            colours: details.colours[rowid] ?? [], featurePrint: row[9].data.map(VectorMath.decode),
            embedding: row[10].data.map(VectorMath.decode), embeddingModel: row[11].string,
            analysisVersion: Int(row[6].int ?? 0), analysisComplete: row[7].int == 1,
            indexedAt: Date(timeIntervalSince1970: row[8].double ?? 0))
    }

    /// Asset identifiers whose labels or recognised text match any of `terms` (FTS5).
    public func textMatches(_ terms: [String], in column: FTSColumn) throws -> Set<String> {
        guard let match = FTSQuery.anyOf(terms, columns: [column]) else { return [] }
        return Set(try db.query(
            "SELECT a.asset_id FROM asset_fts f JOIN assets a ON a.id = f.rowid WHERE asset_fts MATCH ?", [.text(match)])
            .compactMap { $0[0].string })
    }

    /// Loads ranking candidates for a plan: FTS and colour hits plus `similar` ids, inside the plan's
    /// date and media filters. A plan with only filters loads the newest assets inside them.
    public func candidates(for plan: SearchPlan, similar: [String: Double] = [:]) throws -> [RankingCandidate] {
        let (filterSQL, filterValues) = Self.filter(plan)
        var rowids: [Int64]
        if !plan.hasContentCriteria && similar.isEmpty {
            rowids = try db.query(
                "SELECT id FROM assets a WHERE \(filterSQL) ORDER BY captured_at DESC LIMIT \(Self.candidateCap)", filterValues)
                .compactMap { $0[0].int }
        } else {
            var found = Set<Int64>()
            let labelTerms = plan.labelGroups.flatMap(\.terms) + plan.freeTerms
            if let match = FTSQuery.anyOf(labelTerms, columns: [.labels]) {
                try db.forEachRow("SELECT rowid FROM asset_fts WHERE asset_fts MATCH ?", [.text(match)]) { if let id = $0[0].int { found.insert(id) } }
            }
            if let match = FTSQuery.anyOf(plan.freeTerms + plan.requiredText, columns: [.body], prefix: true) {
                try db.forEachRow("SELECT rowid FROM asset_fts WHERE asset_fts MATCH ?", [.text(match)]) { if let id = $0[0].int { found.insert(id) } }
            }
            if !plan.colours.isEmpty {
                let values = plan.colours.map { SQLiteConnection.Value.text($0.rawValue) }
                try db.forEachRow(
                    "SELECT DISTINCT asset_rowid FROM colours WHERE colour IN (\(Self.placeholders(values.count)))", values
                ) { if let id = $0[0].int { found.insert(id) } }
            }
            if !similar.isEmpty {
                for chunk in Array(similar.keys).chunked(400) {
                    try db.forEachRow(
                        "SELECT id FROM assets WHERE asset_id IN (\(Self.placeholders(chunk.count)))", chunk.map(SQLiteConnection.Value.text)
                    ) { if let id = $0[0].int { found.insert(id) } }
                }
            }
            rowids = Array(found)
        }
        var out: [RankingCandidate] = []
        for chunk in rowids.chunked(400) {
            let rows = try db.query(
                """
                SELECT a.id, a.asset_id, a.captured_at, a.media, f.body FROM assets a
                LEFT JOIN asset_fts f ON f.rowid = a.id
                WHERE a.id IN (\(Self.placeholders(chunk.count))) AND \(filterSQL)
                """, chunk.map(SQLiteConnection.Value.int) + filterValues)
            let details = try loadDetails(rows.compactMap { $0[0].int })
            for row in rows {
                guard let rowid = row[0].int, let assetId = row[1].string else { continue }
                out.append(RankingCandidate(
                    assetId: assetId, capturedAt: row[2].double.map(Date.init(timeIntervalSince1970:)),
                    media: PhotoMediaKind(rawValue: row[3].string ?? "") ?? .photo,
                    labels: details.labels[rowid] ?? [], text: row[4].string ?? "",
                    colours: details.colours[rowid] ?? [], similarity: similar[assetId]))
            }
            if out.count >= Self.candidateCap { break }
        }
        return out
    }

    /// Text-image embedding neighbours (cosine ≥ `minimum`) inside the plan's filters, best first.
    public func embeddingNeighbours(of query: [Float], model: String, plan: SearchPlan, minimum: Double, limit: Int) throws -> [String: Double] {
        let (filterSQL, filterValues) = Self.filter(plan)
        var best: [(String, Double)] = []
        try db.forEachRow(
            "SELECT asset_id, embedding FROM assets a WHERE embedding_model = ? AND embedding IS NOT NULL AND \(filterSQL)",
            [.text(model)] + filterValues
        ) { row in
            guard let id = row[0].string, let data = row[1].data,
                  let sim = VectorMath.cosine(query, VectorMath.decode(data)), sim >= minimum else { return }
            best.append((id, sim))
            if best.count > limit * 2 {
                best.sort { $0.1 > $1.1 }
                best.removeLast(best.count - limit)
            }
        }
        return Dictionary(best.sorted { $0.1 > $1.1 }.prefix(limit).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
    }

    /// Assets that look like `assetId` (Vision feature print distance, smaller is closer).
    public func similarByFeaturePrint(to assetId: String, limit: Int) throws -> [(assetId: String, distance: Double)] {
        guard let data = try db.query("SELECT feature_print FROM assets WHERE asset_id = ?", [.text(assetId)]).first?[0].data else {
            return []
        }
        let reference = VectorMath.decode(data)
        var all: [(String, Double)] = []
        try db.forEachRow("SELECT asset_id, feature_print FROM assets WHERE feature_print IS NOT NULL AND asset_id <> ?", [.text(assetId)]) { row in
            guard let id = row[0].string, let blob = row[1].data, let d = VectorMath.euclidean(reference, VectorMath.decode(blob)) else { return }
            all.append((id, d))
        }
        return all.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }.prefix(max(0, limit)).map { (assetId: $0.0, distance: $0.1) }
    }

    // MARK: - Helpers

    private func loadDetails(_ rowids: [Int64]) throws -> (labels: [Int64: [VisualLabel]], colours: [Int64: [RegionColour]]) {
        var labels = [Int64: [VisualLabel]]()
        var colours = [Int64: [RegionColour]]()
        for chunk in rowids.chunked(400) {
            let marks = Self.placeholders(chunk.count)
            let values = chunk.map(SQLiteConnection.Value.int)
            try db.forEachRow("SELECT asset_rowid, label, confidence FROM labels WHERE asset_rowid IN (\(marks))", values) { row in
                guard let id = row[0].int, let name = row[1].string else { return }
                labels[id, default: []].append(VisualLabel(name: name, confidence: row[2].double ?? 0))
            }
            try db.forEachRow("SELECT asset_rowid, region, colour, fraction FROM colours WHERE asset_rowid IN (\(marks))", values) { row in
                guard let id = row[0].int, let region = row[1].string.flatMap(ColourRegion.init),
                      let colour = row[2].string.flatMap(NamedColour.init(rawValue:)) else { return }
                colours[id, default: []].append(RegionColour(region: region, colour: colour, fraction: row[3].double ?? 0))
            }
        }
        return (labels, colours)
    }

    private static func filter(_ plan: SearchPlan) -> (String, [SQLiteConnection.Value]) {
        var clauses = ["1 = 1"]
        var values: [SQLiteConnection.Value] = []
        if let interval = plan.dateInterval {
            clauses.append("a.captured_at BETWEEN ? AND ?")
            values += [.double(interval.start.timeIntervalSince1970), .double(interval.end.timeIntervalSince1970)]
        }
        let kinds = PhotoMediaKind.allCases.filter(plan.media.admits)
        if kinds.count < PhotoMediaKind.allCases.count {
            clauses.append("a.media IN (\(placeholders(kinds.count)))")
            values += kinds.map { .text($0.rawValue) }
        }
        return (clauses.joined(separator: " AND "), values)
    }

    private static func placeholders(_ n: Int) -> String {
        Array(repeating: "?", count: n).joined(separator: ", ")
    }
}

public enum FTSColumn: String, Sendable {
    case labels, body
}

/// Builds FTS5 MATCH expressions from untrusted words: every term is a quoted phrase, so operators
/// and syntax characters in a query are never interpreted.
enum FTSQuery {
    static func anyOf(_ terms: [String], columns: [FTSColumn], prefix: Bool = false) -> String? {
        let phrases = terms.compactMap { term -> String? in
            let normal = TextNormalizer.normalize(term)
            guard !normal.isEmpty else { return nil }
            let quoted = "\"" + normal.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            return prefix && normal.count >= 4 && !normal.contains(" ") ? quoted + " *" : quoted
        }
        guard !phrases.isEmpty else { return nil }
        let unique = Array(Set(phrases)).sorted()
        return "{\(columns.map(\.rawValue).joined(separator: " "))} : (\(unique.joined(separator: " OR ")))"
    }
}

extension Array {
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
