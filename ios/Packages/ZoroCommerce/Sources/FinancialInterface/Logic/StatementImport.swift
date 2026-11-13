import CommerceSupport
import Foundation
import Observation
import ZoroCore

/// Statement import: pick a PDF, CSV or Excel file, upload it, show what the server imported.
///
/// States: idle → chosen → uploading → finished(status) | failed; a file that cannot be sent is
/// `rejected` before any upload. Only `chosen` can upload; `reset` returns to idle from anywhere
/// except `uploading`.
@MainActor
@Observable
public final class StatementImportViewModel {
    public enum State: Equatable, Sendable {
        case idle
        case chosen(UploadFile)
        case rejected(String)
        case uploading(filename: String)
        case finished(ImportStatus)
        case failed(ScreenFailure)
    }

    public static let maxBytes = 20 * 1024 * 1024
    public static let acceptedExtensions = ["pdf", "csv", "xlsx"]

    public private(set) var state: State = .idle
    public var accountName = ""
    public private(set) var recent: [ImportStatus] = []

    @ObservationIgnored private let client: FinanceClient

    public init(client: FinanceClient) { self.client = client }

    public static func mimeType(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "pdf": "application/pdf"
        case "csv": "text/csv"
        case "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        default: nil
        }
    }

    /// Validates a picked file. Mirrors the server's rules so obvious mistakes never leave the device.
    public func choose(filename: String, data: Data) {
        guard !isUploading else { return }
        let ext = (filename as NSString).pathExtension.lowercased()
        if ext == "xls" {
            state = .rejected("Old .xls workbooks cannot be read. Save it as .xlsx or .csv, then choose it again.")
        } else if Self.mimeType(forExtension: ext) == nil {
            state = .rejected("Choose a PDF, CSV or Excel (.xlsx) statement.")
        } else if data.isEmpty {
            state = .rejected("That file is empty. Download the statement again, then choose it.")
        } else if data.count > Self.maxBytes {
            state = .rejected("That file is over 20 MB. Download a shorter period, then choose it.")
        } else {
            state = .chosen(UploadFile(filename: filename, data: data, mimeType: Self.mimeType(forExtension: ext)!))
        }
    }

    /// The file importer could not read the file (permission, iCloud download …).
    public func chooseFailed(_ error: Error) {
        state = .rejected("Could not open that file. Make sure it is downloaded to this device, then choose it again.")
    }

    public var isUploading: Bool {
        if case .uploading = state { true } else { false }
    }

    public var canUpload: Bool {
        if case .chosen = state { true } else { false }
    }

    public func upload() async {
        guard case .chosen(let file) = state else { return }
        state = .uploading(filename: file.filename)
        do {
            let status = try await client.uploadStatement(file, accountName: accountName)
            state = .finished(status)
            recent.removeAll { $0.id == status.id }
            recent.insert(status, at: 0)
        } catch {
            state = .failed(ScreenFailure.from(error, subject: "the statement"))
        }
    }

    public func reset() {
        guard !isUploading else { return }
        state = .idle
    }

    public func loadRecent() async {
        if let list = try? await client.imports() { recent = list }
    }

    /// One sentence on what happened, built from the server's counts.
    public static func outcome(_ s: ImportStatus) -> String {
        if s.alreadyImported { return "\(s.filename) was imported before, so nothing changed." }
        switch s.status {
        case .failed:
            let reason = s.message.isEmpty ? "No transactions could be read." : s.message
            return "\(reason) Check that it is a bank or card statement, then try another file."
        case .completed, .partial:
            var parts = ["Imported \(s.rowsImported) \(s.rowsImported == 1 ? "transaction" : "transactions")"]
            if s.rowsDuplicate > 0 { parts.append("\(s.rowsDuplicate) already there") }
            if s.rowsError > 0 { parts.append("\(s.rowsError) \(s.rowsError == 1 ? "row" : "rows") could not be read") }
            var text = parts.joined(separator: "; ") + "."
            if s.balanceCheck == "mismatch" { text += " The running balance does not add up; compare it with your bank." }
            return text
        }
    }
}
