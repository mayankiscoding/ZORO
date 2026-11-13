import CommerceSupport
import Foundation
import ZoroCore

/// Answer of `POST /v1/approvals/{approval_id}/decision` (backend `app/schemas/turns.py`,
/// `ApprovalDecisionResult`). `owner` says who was waiting: a suspended turn ("turn"), an MCP call
/// ("mcp") or an automation run ("automation"); `status` is that owner's word for what happened next.
public struct ApprovalDecisionResult: Codable, Sendable, Equatable {
    public var approvalId: String
    public var owner: String
    public var approved: Bool
    public var status: String
    public var turnId: String?
    public var runId: String?
    /// For a turn: the resumed turn's events, in order (kept raw; the app shows the status line).
    public var events: [JSONObject]
    public var result: JSONObject?

    public init(
        approvalId: String, owner: String, approved: Bool, status: String, turnId: String? = nil, runId: String? = nil,
        events: [JSONObject] = [], result: JSONObject? = nil
    ) {
        self.approvalId = approvalId
        self.owner = owner
        self.approved = approved
        self.status = status
        self.turnId = turnId
        self.runId = runId
        self.events = events
        self.result = result
    }

    enum CodingKeys: String, CodingKey {
        case approvalId = "approval_id"
        case owner, approved, status
        case turnId = "turn_id"
        case runId = "run_id"
        case events, result
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        approvalId = try c.decode(String.self, forKey: .approvalId)
        owner = try c.decode(String.self, forKey: .owner)
        approved = try c.decode(Bool.self, forKey: .approved)
        status = try c.decode(String.self, forKey: .status)
        turnId = try c.decodeIfPresent(String.self, forKey: .turnId)
        runId = try c.decodeIfPresent(String.self, forKey: .runId)
        events = try c.decodeIfPresent([JSONObject].self, forKey: .events) ?? []
        result = try c.decodeIfPresent(JSONObject.self, forKey: .result)
    }
}

extension APIRequest {
    /// `POST /v1/approvals/{approval_id}/decision` with the signed decision as the body.
    public static func approvalDecision(_ decision: ApprovalDecision) throws -> APIRequest {
        try .json(.post, "/v1/approvals/\(segment(decision.approvalId))/decision", body: decision)
    }
}

extension ZoroAPI {
    /// Answers any approval (a turn's, an MCP call's, an automation run's, another device's request).
    /// The server verifies the signature and runs exactly the digested arguments, or nothing.
    public func decideApproval(_ decision: ApprovalDecision) async throws -> ApprovalDecisionResult {
        try await send(.approvalDecision(decision), as: ApprovalDecisionResult.self)
    }
}

/// `FileUploading` over the app's authenticated `ZoroAPI`: the multipart body goes out with its own
/// content type through `APIRequest.raw`, so the bearer token and the one re-authentication on 401 are
/// the same as for every other call. Statement import and holdings CSV use it via `\.commerceFileUploader`.
public struct APIFileUploader: FileUploading {
    private let api: any ZoroAPI
    public init(api: any ZoroAPI) { self.api = api }

    public func upload(_ request: MultipartRequest) async throws -> Data {
        try await api.sendRaw(.raw(.post, request.path, body: request.body, contentType: request.contentType))
    }
}
