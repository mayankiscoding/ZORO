import CommerceSupport
import Foundation
import SwiftUI
import ZoroCore
import ZoroDesign

// Views for the `portfolio` and `stock_analysis` UICard kinds. A payload that cannot be decoded is
// reported plainly, never filled in.

public enum InvestmentCardDecoding {
    public static func portfolio(_ card: UICard) -> PortfolioSummary? {
        guard card.kind == "portfolio" else { return nil }
        return try? card.decodePayload(PortfolioSummary.self)
    }
    public static func analysis(_ card: UICard) -> StockAnalysis? {
        guard card.kind == "stock_analysis" else { return nil }
        return try? card.decodePayload(StockAnalysis.self)
    }
}

struct UnreadableInvestmentCard: View {
    let title: String
    var body: some View {
        ZoroCard {
            ZoroStateView(.error, message: "\(title) could not be shown in this version of the app. Ask ZORO again, or open Investments.")
        }
    }
}

public struct PortfolioCardView: View {
    let card: UICard
    let portfolio: PortfolioSummary?

    public init(card: UICard) {
        self.card = card
        self.portfolio = InvestmentCardDecoding.portfolio(card)
    }

    public var body: some View {
        if let portfolio {
            PortfolioSummaryView(portfolio: portfolio)
        } else {
            UnreadableInvestmentCard(title: card.title ?? "This portfolio")
        }
    }
}

public struct StockAnalysisCardView: View {
    let card: UICard
    let analysis: StockAnalysis?

    public init(card: UICard) {
        self.card = card
        self.analysis = InvestmentCardDecoding.analysis(card)
    }

    public var body: some View {
        if let analysis {
            StockAnalysisView(analysis: analysis)
        } else {
            UnreadableInvestmentCard(title: card.title ?? "This analysis")
        }
    }
}
