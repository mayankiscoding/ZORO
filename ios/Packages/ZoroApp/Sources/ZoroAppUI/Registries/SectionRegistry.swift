import SwiftUI
import ZoroDesign

/// Maps each `AppSection` to the screen a feature package provides. The shell never imports feature
/// packages: the composition root registers their screens here. A section nobody registered shows an
/// honest "not connected yet" state instead of an empty or invented screen.
@MainActor
public final class SectionRegistry {
    public typealias Builder = @MainActor () -> AnyView

    private var builders: [AppSection: Builder] = [:]

    public init() {}

    /// Registers (or replaces) the screen for a section.
    public func register<Content: View>(_ section: AppSection, @ViewBuilder content: @escaping @MainActor () -> Content) {
        builders[section] = { AnyView(content()) }
    }

    public func unregister(_ section: AppSection) {
        builders[section] = nil
    }

    public func isRegistered(_ section: AppSection) -> Bool { builders[section] != nil }

    public var registeredSections: Set<AppSection> { Set(builders.keys) }

    /// The registered screen, or the "not connected yet" state.
    public func view(for section: AppSection) -> AnyView {
        if let builder = builders[section] { return builder() }
        return AnyView(SectionNotConnectedView(section: section))
    }
}

/// Shown for a section whose screen is not part of this build yet.
public struct SectionNotConnectedView: View {
    let section: AppSection
    public init(section: AppSection) { self.section = section }

    public static func message(for section: AppSection) -> String {
        "\(section.title) is not connected yet. This build doesn't include its screen, so there is nothing to show here."
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZoroSpace.l.value) {
                Label(section.title, systemImage: section.symbol)
                    .zoroText(.heading)
                    .labelStyle(.titleAndIcon)
                ZoroStateView(.empty, message: Self.message(for: section))
            }
            .padding(ZoroSpace.l.value)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(ZoroNeutral.background)
        .navigationTitle(section.title)
    }
}
