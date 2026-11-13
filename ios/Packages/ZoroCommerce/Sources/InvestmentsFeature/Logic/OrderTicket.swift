import CommerceSupport
import Foundation
import Observation
import ZoroCore

/// What the owner wants a ticket for. ZORO never places orders: the CRITICAL
/// `investment.prepare_order_ticket` tool returns what to enter in the broker's own app, and only
/// after a biometric approval signed on this device.
public struct OrderTicketDraft: Equatable, Sendable {
    public var symbol = ""
    public var exchange = "NSE"
    public var side = "buy"
    public var quantity = 1
    public var limitPriceText = ""
    public var broker = "kite"

    public init() {}

    public var limitPrice: Decimal? {
        let t = limitPriceText.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : DecimalString.parse(t)
    }

    public var validationMessage: String? {
        if WatchlistViewModel.normalise(symbol) == nil { return "Enter a symbol like INFY." }
        if !(1...1_000_000).contains(quantity) { return "Enter a quantity of at least 1." }
        if !limitPriceText.trimmingCharacters(in: .whitespaces).isEmpty, (limitPrice ?? 0) <= 0 {
            return "Enter the limit price in rupees, or leave it empty for a market order."
        }
        return nil
    }

    /// The sentence sent as a turn. Every value is the owner's own input.
    public var request: String {
        let s = WatchlistViewModel.normalise(symbol) ?? symbol
        let price = limitPrice.map { "a limit order at \(DecimalString.format($0)) rupees" } ?? "a market order"
        return "Prepare an order ticket to \(side) \(quantity) \(s) on \(exchange) as \(price), delivery, for \(broker). Do not place it."
    }
}

/// Runs the ticket request as a normal turn, so the server's policy engine decides the approval level;
/// this device only signs (through `ApprovalHandling`) or declines.
@MainActor
@Observable
public final class OrderTicketViewModel {
    public enum Step: Equatable, Sendable {
        case draft
        case working
        case awaitingApproval(ApprovalRequest)
        case done(String)
        case declined
        case failed(ScreenFailure)
    }

    public var draft = OrderTicketDraft()
    public private(set) var step: Step = .draft
    public private(set) var reply = ""

    @ObservationIgnored private let api: any ZoroAPI
    @ObservationIgnored private let approvals: any ApprovalHandling
    @ObservationIgnored private let platform: DevicePlatform

    public init(api: any ZoroAPI, approvals: any ApprovalHandling, platform: DevicePlatform) {
        self.api = api
        self.approvals = approvals
        self.platform = platform
    }

    public func send() async {
        guard draft.validationMessage == nil else { return }
        step = .working
        reply = ""
        let request = TurnRequest(input: TurnInput(text: draft.request), client: ClientContext(platform: platform))
        await consume(api.startTurn(request))
    }

    private func consume(_ stream: AsyncThrowingStream<TurnEvent, Error>) async {
        var turnId: String?
        var pending: ApprovalRequest?
        do {
            for try await event in stream {
                switch event {
                case .turnStarted(let s): turnId = s.turnId
                case .textDelta(let d): reply += d.text
                case .approvalRequired(let a):
                    pending = a.approval
                    step = .awaitingApproval(a.approval)
                case .turnCompleted:
                    step = .done(reply.isEmpty ? "ZORO finished without a ticket. Check the conversation for details." : reply)
                default: break
                }
            }
        } catch {
            step = .failed(ScreenFailure.from(error, subject: "the order ticket"))
            return
        }
        guard let approval = pending, case .awaitingApproval = step else {
            if case .working = step { step = .done(reply.isEmpty ? "ZORO finished without a ticket." : reply) }
            return
        }
        await decide(approval, turnId: approval.turnId ?? turnId)
    }

    private func decide(_ approval: ApprovalRequest, turnId: String?) async {
        guard let turnId else {
            step = .failed(ScreenFailure(kind: .error, message: "The server did not say which turn to resume. Ask again.", retryable: false))
            return
        }
        let decision: ApprovalDecision
        do {
            decision = try await approvals.decide(approval)
        } catch ZoroError.userCancelled {
            step = .declined
            return
        } catch {
            step = .failed(ScreenFailure.from(error, subject: "the approval"))
            return
        }
        if !decision.approved {
            step = .declined
        } else {
            step = .working
        }
        reply = ""
        await consume(api.resumeTurn(id: turnId, ResumeRequest(approval: decision)))
        if !decision.approved { step = .declined }
    }

    public func reset() {
        step = .draft
        reply = ""
    }
}
