import AppIntents
import Testing
@testable import ZoroAppUI

@Suite("Section display representations")
struct AppSectionDisplayTests {
    @Test func literalCoversEveryCaseWithItsTitle() {
        #expect(AppSection.caseDisplayRepresentations.count == AppSection.allCases.count)
        for section in AppSection.allCases {
            let rep = AppSection.caseDisplayRepresentations[section]
            #expect(rep != nil, "missing \(section)")
            if let rep { #expect(String(localized: rep.title) == section.title) }
        }
    }
}
