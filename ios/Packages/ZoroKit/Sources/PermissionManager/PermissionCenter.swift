import Foundation
import Observation
import ZoroCore

/// Reports permission status and asks for access in context (the first time a feature needs it).
///
/// Rules: the system sheet is only ever shown from `request`, and only while the state is
/// `notDetermined`; a denied permission is never re-asked (the outcome says "open Settings");
/// concurrent requests for one kind share one system call.
@MainActor @Observable
public final class PermissionCenter {
    /// Last known status per kind. A kind with no provider reads as `.unsupported`.
    public private(set) var statuses: [PermissionKind: PermissionStatus]
    /// Language of the purpose sentences.
    public var language: PermissionCopyLanguage

    @ObservationIgnored private let providers: [PermissionKind: any PermissionProviding]
    @ObservationIgnored private var inFlight: [PermissionKind: Task<PermissionOutcome, Never>] = [:]

    public init(providers: [any PermissionProviding], language: PermissionCopyLanguage = .english) {
        var map: [PermissionKind: any PermissionProviding] = [:]
        for provider in providers { map[provider.kind] = provider }
        self.providers = map
        self.language = language
        self.statuses = Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, PermissionStatus.notDetermined) })
        for kind in PermissionKind.allCases where map[kind] == nil { statuses[kind] = .unsupported }
    }

    /// The center wired to the real frameworks for this platform.
    public static func system(language: PermissionCopyLanguage = .english) -> PermissionCenter {
        PermissionCenter(providers: SystemPermissionProviders.all(), language: language)
    }

    // MARK: Status

    public func status(for kind: PermissionKind) -> PermissionStatus { statuses[kind] ?? .unsupported }

    /// Reads the live state of one kind (never shows a sheet).
    @discardableResult
    public func refresh(_ kind: PermissionKind) async -> PermissionStatus {
        guard let provider = providers[kind] else { return .unsupported }
        let status = await provider.status()
        statuses[kind] = status
        return status
    }

    /// Reads every kind. Call when the app becomes active: the owner may have changed Settings.
    public func refreshAll() async {
        for kind in PermissionKind.allCases { await refresh(kind) }
    }

    // MARK: Copy

    public func purpose(for kind: PermissionKind) -> String { kind.purpose(language) }

    /// What a pre-permission screen shows and what its button does.
    public func prompt(for kind: PermissionKind) -> PermissionPrompt {
        let status = status(for: kind)
        let action: PermissionPrompt.Action =
            status.canRequest ? .requestAccess : (status.needsSettings ? .openSettings : .none)
        return PermissionPrompt(
            kind: kind, status: status, title: kind.title(language), purpose: kind.purpose(language), action: action)
    }

    // MARK: Requests

    /// Asks for `kind` if it has not been asked yet. Safe to call whenever a feature needs the permission.
    public func request(_ kind: PermissionKind) async -> PermissionOutcome {
        if let running = inFlight[kind] { return await running.value }
        guard let provider = providers[kind] else {
            return PermissionOutcome(kind: kind, status: .unsupported, prompted: false)
        }
        let task = Task { @MainActor () -> PermissionOutcome in
            let current = await provider.status()
            guard current.canRequest else {
                self.statuses[kind] = current
                return PermissionOutcome(kind: kind, status: current, prompted: false)
            }
            let result = await provider.request()
            self.statuses[kind] = result
            return PermissionOutcome(kind: kind, status: result, prompted: true)
        }
        inFlight[kind] = task
        let outcome = await task.value
        inFlight[kind] = nil
        return outcome
    }

    /// Asks for several kinds one after another (sheets never stack). Stops at the first one the
    /// owner refuses, so a flow does not keep asking after a "no". Returns the outcomes reached.
    public func request(all kinds: [PermissionKind]) async -> [PermissionOutcome] {
        var outcomes: [PermissionOutcome] = []
        for kind in kinds {
            if Task.isCancelled { break }
            let outcome = await request(kind)
            outcomes.append(outcome)
            if !outcome.isUsable && outcome.status != .unsupported { break }
        }
        return outcomes
    }

    /// True when `kind` can be used right now, without asking.
    public func isUsable(_ kind: PermissionKind) -> Bool { status(for: kind).allowsUse }
}
