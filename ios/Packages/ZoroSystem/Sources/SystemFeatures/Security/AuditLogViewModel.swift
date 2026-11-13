import Foundation
import Observation
import ZoroCore

public enum AuditCopy {
    public static func decisionLabel(_ decision: AuditDecision) -> String {
        switch decision {
        case .allowed: "Allowed"
        case .approved: "Approved"
        case .denied: "Denied"
        case .blocked: "Blocked"
        case .failed: "Couldn't finish"
        case .info: "Recorded"
        }
    }

    public static func riskLabel(_ risk: RiskLevel) -> String {
        switch risk {
        case .low: "Low risk"
        case .medium: "Medium risk"
        case .high: "High risk"
        case .critical: "Critical risk"
        }
    }

    /// "policy.decision" -> "Policy decision".
    public static func actionTitle(_ action: String) -> String {
        SystemFormat.sentenceCase(action.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " "))
    }
}

/// The append-only audit log, newest page first, with "load more".
@MainActor
@Observable
public final class AuditLogViewModel {
    public private(set) var phase: ScreenPhase = .idle
    public private(set) var records: [AuditRecord] = []
    public private(set) var hasMore = false
    public private(set) var isLoadingMore = false
    public private(set) var loadMoreFailure: String?
    public var decisionFilter: AuditDecision?

    @ObservationIgnored private let api: any ZoroAPI
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private var pages = PageAccumulator<AuditRecord>(id: { $0.id })
    @ObservationIgnored private var generation = 0

    public init(api: any ZoroAPI, pageSize: Int = 50) {
        self.api = api
        self.pageSize = max(1, min(pageSize, 200))
    }

    public var visibleRecords: [AuditRecord] {
        guard let decisionFilter else { return records }
        return records.filter { $0.decision == decisionFilter }
    }

    public var emptyMessage: String {
        decisionFilter == nil
            ? "Nothing has been recorded yet. Every approval and tool run shows up here."
            : "Nothing with that result in what's loaded. Load more or clear the filter."
    }

    public func load() async {
        phase = .loading
        loadMoreFailure = nil
        generation += 1
        let gen = generation
        do {
            let page = try await api.auditLog(cursor: nil, limit: pageSize)
            guard gen == generation else { return }
            pages.reset(with: page)
            publish()
            phase = records.isEmpty ? .empty : .loaded
        } catch {
            guard gen == generation, let next = SystemFailure.phase(for: error) else { return }
            phase = next
        }
    }

    public func loadMore() async {
        guard !isLoadingMore, let cursor = pages.nextCursor else { return }
        isLoadingMore = true
        loadMoreFailure = nil
        defer { isLoadingMore = false }
        let gen = generation
        do {
            let page = try await api.auditLog(cursor: cursor, limit: pageSize)
            guard gen == generation else { return }
            pages.append(page, requestedCursor: cursor)
            publish()
        } catch {
            if let message = SystemFailure.message(for: error) { loadMoreFailure = message }
        }
    }

    private func publish() {
        records = pages.items
        hasMore = pages.hasMore
    }
}
