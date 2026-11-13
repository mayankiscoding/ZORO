import FinancialInterface
import FitnessFeature
import InvestmentsFeature
import MusicFeature
import PhotosFeature
import ShoppingInterface
import SwiftUI
import SystemFeatures
import ZoroAppUI
import ZoroCore

/// Puts every feature package's screens and card views into the shell's registries.
@MainActor
public enum Registrations {
    /// Card kinds the backend sends (see `UICard(kind=…)` in backend/app) that have a dedicated view.
    /// Anything else (sources, emails, home_state, message_draft, memory…) uses the generic card.
    public static let cardKinds: [String] = [
        "products", "basket", "basket_comparison", "finance_summary", "transactions", "portfolio", "stock_analysis",
        "fitness_summary", "photo_query", "music",
    ]

    /// All fifteen sections. Home and Live voice are the shell's own screens (the Mac sidebar and the
    /// iPhone ZORO tab draw them directly); registering them too keeps a pushed link to either honest.
    public static func registerSections(
        in registry: SectionRegistry, shell: ZoroAppShell, system: SystemFeaturesContainer, inbox: ApprovalInbox
    ) {
        registry.register(.home) {
            HomeView(model: shell.home, navigation: shell.navigation, cards: shell.cards, pairAgain: { shell.pairAgain() })
        }
        registry.register(.liveVoice) {
            LiveVoiceView(model: shell.home) { shell.navigation.isLiveVoicePresented = false }
        }
        registry.register(.shopping) { ShoppingHomeView() }
        registry.register(.finance) { FinanceDashboardView() }
        registry.register(.investments) { InvestmentsHomeView() }
        registry.register(.fitness) { FitnessHomeView() }
        registry.register(.photos) { PhotoSearchView() }
        registry.register(.music) { MusicHomeView() }
        registry.register(.activity) { ActivityScreen(inbox: inbox, system: system) }
        registry.register(.history) { SystemScreenView(.history, container: system) }
        registry.register(.memory) { SystemScreenView(.memory, container: system) }
        registry.register(.integrations) { SystemScreenView(.integrations, container: system) }
        registry.register(.deviceControl) { SystemScreenView(.deviceControl, container: system) }
        registry.register(.security) { SystemScreenView(.security, container: system) }
        registry.register(.settings) { SystemScreenView(.settings, container: system) }
    }

    public static func registerCards(in registry: CardRendererRegistry) {
        registry.register(kind: "products") { ProductsCardView(card: $0) }
        registry.register(kind: "basket") { BasketCardView(card: $0) }
        registry.register(kind: "basket_comparison") { BasketComparisonCardView(card: $0) }
        registry.register(kind: "finance_summary") { FinanceSummaryCardView(card: $0) }
        registry.register(kind: "transactions") { TransactionsCardView(card: $0) }
        registry.register(kind: "portfolio") { PortfolioCardView(card: $0) }
        registry.register(kind: "stock_analysis") { StockAnalysisCardView(card: $0) }
        registry.register(kind: "fitness_summary") { FitnessSummaryCardView(card: $0) }
        registry.register(kind: "photo_query") { PhotoQueryCardView(card: $0) }
        registry.register(kind: "music") { MusicCardView(card: $0) }
    }
}
