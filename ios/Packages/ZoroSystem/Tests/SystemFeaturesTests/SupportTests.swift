import Foundation
import Testing
import ZoroCore
@testable import SystemFeatures

@Suite("Failure mapping and pagination helpers")
struct SupportTests {
    @Test func notPairedIsDisconnectedAndNotRetryable() {
        let phase = SystemFailure.phase(for: ZoroError.notPaired)
        #expect(phase?.isDisconnected == true)
        #expect(phase?.failure?.retryable == false)
        #expect(phase?.failure?.message == SystemCopy.notPaired)
    }

    @Test func transportAndTimeoutAreDisconnectedWithTailscaleHint() {
        let errors: [Error] = [ZoroError.transport("x"), ZoroError.timeout, URLError(.notConnectedToInternet)]
        for error in errors {
            let phase = SystemFailure.phase(for: error)
            #expect(phase?.isDisconnected == true)
            #expect(phase?.failure?.message.contains("Tailscale") == true)
        }
    }

    @Test func unauthorizedMeansDeviceRemoved() {
        #expect(SystemFailure.phase(for: ZoroError.unauthorized)?.failure?.message == SystemCopy.deviceRemoved)
    }

    @Test func serverErrorIsFailedWithServerMessageAsSentence() {
        let body = ErrorBody(code: "validation_error", message: "The request body is not valid")
        let phase = SystemFailure.phase(for: ZoroError.http(status: 422, body: body))
        #expect(phase == .failed(ScreenFailure(message: "The request body is not valid.", retryable: false)))
    }

    @Test func killSwitchErrorPointsToSecurity() {
        let body = ErrorBody(code: "kill_switch_active", message: "The kill switch is on.", retryable: false)
        let phase = SystemFailure.phase(for: ZoroError.http(status: 503, body: body))
        #expect(phase?.failure?.message == SystemCopy.killSwitchOn)
    }

    @Test func cancellationLeavesScreenAlone() {
        #expect(SystemFailure.phase(for: CancellationError()) == nil)
        #expect(SystemFailure.phase(for: ZoroError.userCancelled) == nil)
        #expect(SystemNotice.failed(ZoroError.userCancelled, action: "Deleting") == nil)
    }

    @Test func noticeNamesTheActionThatDidNotHappen() {
        let notice = SystemNotice.failed(ZoroError.timeout, action: "Deleting")
        #expect(notice?.kind == .failure)
        #expect(notice?.text.hasPrefix("Deleting didn't happen.") == true)
    }

    @Test func copyHasNoExclamationMarksOrAllCaps() {
        let all = [SystemCopy.notPaired, SystemCopy.deviceRemoved, SystemCopy.unreachable, SystemCopy.killSwitchOn]
            + IntegrationGroup.allCases.flatMap { [$0.title, $0.explanation] }
            + PrivacyMode.allCases.flatMap { [PrivacyCopy.title($0), PrivacyCopy.line($0), PrivacyCopy.explanation($0)] }
        for text in all {
            #expect(!text.contains("!"))
            #expect(text != text.uppercased())
        }
    }

    // MARK: PageAccumulator

    private func page(_ ids: [String], next: String?) -> Page<ConversationSummary> {
        Page(items: ids.map { conversation($0) }, nextCursor: next)
    }

    @Test func accumulatorAppendsWithoutDuplicates() {
        var acc = PageAccumulator<ConversationSummary>(id: { $0.id })
        acc.reset(with: page(["a", "b"], next: "c1"))
        #expect(acc.hasMore)
        acc.append(page(["b", "c"], next: nil), requestedCursor: "c1")
        #expect(acc.items.map(\.id) == ["a", "b", "c"])
        #expect(!acc.hasMore)
        #expect(acc.pagesLoaded == 2)
    }

    @Test func accumulatorStopsOnRepeatedEmptyOrMissingCursor() {
        var acc = PageAccumulator<ConversationSummary>(id: { $0.id })
        acc.reset(with: page(["a"], next: "c1"))
        acc.append(page(["b"], next: "c1"), requestedCursor: "c1")  // server repeated the cursor: a loop
        #expect(!acc.hasMore)
        acc.reset(with: page(["a"], next: ""))
        #expect(!acc.hasMore)
        acc.reset(with: page(["a"], next: "c9"))
        acc.append(page([], next: "c10"), requestedCursor: "c9")  // empty page with a cursor: stop
        #expect(!acc.hasMore)
    }

    @Test func accumulatorReplacesRemovesAndReinserts() {
        var acc = PageAccumulator<ConversationSummary>(id: { $0.id })
        acc.reset(with: page(["a", "b", "c"], next: nil))
        acc.replace(conversation("b", "Renamed"))
        #expect(acc.items[1].title == "Renamed")
        acc.remove(id: "b")
        #expect(acc.items.map(\.id) == ["a", "c"])
        acc.insert(conversation("b"), at: 1)
        acc.insert(conversation("b"), at: 0)  // already there: ignored
        #expect(acc.items.map(\.id) == ["a", "b", "c"])
    }

    // MARK: Formatting

    @Test func usdFormatting() {
        #expect(SystemFormat.usd(0) == "$0.0000")
        #expect(SystemFormat.usd(Decimal(string: "0.00425")!) == "$0.0043")
        #expect(SystemFormat.usd(Decimal(string: "12.5")!) == "$12.50")
        #expect(SystemFormat.usd(Decimal(string: "1234567.891")!) == "$1,234,567.89")
        #expect(SystemFormat.usd(Decimal(string: "-0.5")!) == "\u{2212}$0.5000")
    }

    @Test func toolTitles() {
        #expect(SystemFormat.toolTitle("finance.spending_summary") == "Spending summary")
        #expect(SystemFormat.toolTitle("ping") == "Ping")
    }
}
