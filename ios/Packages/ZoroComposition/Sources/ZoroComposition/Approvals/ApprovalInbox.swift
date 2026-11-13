import Foundation
import Observation
import ZoroCore

/// Approvals that arrive outside a live turn: an MCP call, an automation routine, or another device's
/// request. The backend pushes them over the device channel (`approval_required` frames) and lists the
/// waiting ones at `GET /v1/approvals/pending`. Each is shown with the same approval sheet as a turn
/// approval (through `ApprovalHandling`, which signs on this device) and answered at
/// `POST /v1/approvals/{id}/decision`.
@MainActor
@Observable
public final class ApprovalInbox {
    public enum Phase: Equatable {
        case loading
        case loaded
        /// One sentence with the next step.
        case failed(String)
        /// Not paired or the server can't be reached.
        case disconnected(String)
    }

    public private(set) var pending: [ApprovalRequest] = []
    public private(set) var phase: Phase = .loading
    /// The last answer, in one sentence ("Approved. Sending now." / "Declined. Nothing was sent.").
    public private(set) var lastOutcome: String?
    /// The approval being answered right now (the sheet is up).
    public private(set) var answering: String?

    @ObservationIgnored private let api: any ZoroAPI
    @ObservationIgnored private let approvals: any ApprovalHandling
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Approvals answered on this device, so a late push of the same id is not shown again.
    @ObservationIgnored private var answered: Set<String> = []

    public init(api: any ZoroAPI, approvals: any ApprovalHandling, now: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api
        self.approvals = approvals
        self.now = now
    }

    public var isEmpty: Bool { pending.isEmpty }

    /// Reloads the waiting approvals from the server; expired ones are dropped.
    public func refresh() async {
        if pending.isEmpty { phase = .loading }
        do {
            let items = try await api.pendingApprovals()
            pending = items.filter { $0.expiresAt > now() && !answered.contains($0.approvalId) }
                .sorted { $0.expiresAt < $1.expiresAt }
            phase = .loaded
        } catch {
            phase = Self.phase(for: ZoroError.wrap(error))
        }
    }

    /// A pushed `approval_required` frame: listed, then the sheet asks the owner right away.
    public func receive(_ request: ApprovalRequest) async {
        guard request.expiresAt > now(), !answered.contains(request.approvalId) else { return }
        if !pending.contains(where: { $0.approvalId == request.approvalId }) {
            pending.append(request)
            pending.sort { $0.expiresAt < $1.expiresAt }
        }
        phase = .loaded
        guard answering == nil else { return }  // one sheet at a time; the rest wait in the list
        await answer(request)
    }

    /// Shows the approval sheet; a signed answer (approve or decline) is sent to the server.
    public func answer(_ request: ApprovalRequest) async {
        guard answering == nil else { return }
        answering = request.approvalId
        defer { answering = nil }
        let decision: ApprovalDecision
        do {
            decision = try await approvals.decide(request)
        } catch let error as ZoroError where error == .approvalExpired {
            remove(request.approvalId)
            lastOutcome = "Expired. Ask again to approve."
            return
        } catch {
            // Dismissed or cancelled: it stays waiting, so the owner can answer it later from Activity.
            lastOutcome = nil
            return
        }
        do {
            let result = try await api.decideApproval(decision)
            answered.insert(request.approvalId)
            remove(request.approvalId)
            lastOutcome = result.approved ? "Approved. Sending now." : "Declined. Nothing was sent."
        } catch {
            let z = ZoroError.wrap(error)
            if case .http(status: 409, _) = z {
                answered.insert(request.approvalId)
                remove(request.approvalId)
                lastOutcome = "This was already answered on another device."
            } else if case .http(status: 410, _) = z {
                remove(request.approvalId)
                lastOutcome = "Expired. Ask again to approve."
            } else {
                lastOutcome = "Your answer didn't reach the server. Check the connection and answer again."
            }
        }
    }

    private func remove(_ id: String) {
        pending.removeAll { $0.approvalId == id }
    }

    static func phase(for error: ZoroError) -> Phase {
        switch error {
        case .notPaired:
            return .disconnected("This device isn't connected to a ZORO server. Pair it in Settings to see approvals.")
        case .transport, .timeout:
            return .disconnected("Can't reach your ZORO server. Check that your Mac is awake and on Tailscale.")
        case .unauthorized:
            return .failed("Your server didn't accept this device. Pair it again in Settings.")
        default:
            return .failed("Waiting approvals couldn't be loaded. Pull to try again.")
        }
    }
}
