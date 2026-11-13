import Foundation
import ZoroCore

/// A file the owner picked, ready to send to the server.
public struct UploadFile: Sendable, Equatable {
    public var filename: String
    public var data: Data
    public var mimeType: String

    public init(filename: String, data: Data, mimeType: String) {
        self.filename = filename
        self.data = data
        self.mimeType = mimeType
    }
}

/// Sends a `multipart/form-data` request to the ZORO backend and returns the response body.
///
/// `ZoroAPI.send` always labels a body as JSON, so file uploads need this separate seam. `ZoroApp`
/// wires an implementation through `\.commerceFileUploader`; until then uploads fail with a typed
/// `ZoroError.unavailable` instead of pretending to work.
public protocol FileUploading: Sendable {
    func upload(_ request: MultipartRequest) async throws -> Data
}

/// A ready-to-send multipart request: path, content type and body.
public struct MultipartRequest: Sendable, Equatable {
    public var path: String
    public var boundary: String
    public var body: Data

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    /// Builds the body: text fields first, then the file part.
    public init(path: String, fields: [(String, String)], fileField: String, file: UploadFile,
                boundary: String = "zoro-\(UUID().uuidString)") {
        self.path = path
        self.boundary = boundary
        var body = Data()
        func line(_ s: String) { body.append(Data((s + "\r\n").utf8)) }
        for (name, value) in fields {
            line("--\(boundary)")
            line("Content-Disposition: form-data; name=\"\(Self.escape(name))\"")
            line("")
            line(value)
        }
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"\(Self.escape(fileField))\"; filename=\"\(Self.escape(file.filename))\"")
        line("Content-Type: \(file.mimeType)")
        line("")
        body.append(file.data)
        body.append(Data("\r\n".utf8))
        line("--\(boundary)--")
        self.body = body
    }

    public static func == (lhs: MultipartRequest, rhs: MultipartRequest) -> Bool {
        lhs.path == rhs.path && lhs.boundary == rhs.boundary && lhs.body == rhs.body
    }

    /// Quotes and line breaks cannot appear inside a header parameter.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}

/// The not-configured uploader.
public struct UnavailableFileUploader: FileUploading {
    public init() {}
    public func upload(_ request: MultipartRequest) async throws -> Data {
        throw ZoroError.unavailable(capability: "File upload",
                                    reason: "this build cannot send files to your server yet; import from the Mac app or ask ZORO")
    }
}

/// Decodes an upload response with the contract decoder.
extension FileUploading {
    public func upload<T: Decodable>(_ request: MultipartRequest, as type: T.Type) async throws -> T {
        let data = try await upload(request)
        do {
            return try ZoroJSON.decoder().decode(T.self, from: data)
        } catch {
            throw ZoroError.decoding(String(describing: error))
        }
    }
}

#if canImport(SwiftUI)
import SwiftUI

private struct FileUploaderKey: EnvironmentKey {
    static let defaultValue: any FileUploading = UnavailableFileUploader()
}

extension EnvironmentValues {
    /// Set by `ZoroApp` once it has an uploader; statement and holdings imports use it.
    public var commerceFileUploader: any FileUploading {
        get { self[FileUploaderKey.self] }
        set { self[FileUploaderKey.self] = newValue }
    }
}
#endif
