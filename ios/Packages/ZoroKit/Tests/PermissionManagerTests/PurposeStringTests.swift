import Testing
@testable import PermissionManager

@Suite struct PurposeStringTests {
    @Test(arguments: PermissionKind.allCases)
    func englishPurposeIsOneSentence(kind: PermissionKind) {
        let text = kind.purpose(.english)
        #expect(!text.isEmpty)
        #expect(text.hasSuffix("."))
        #expect(text.filter { ".!?".contains($0) }.count == 1)
        #expect(!text.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) })
        #expect(!kind.title.isEmpty)
    }

    @Test(arguments: PermissionKind.allCases)
    func hindiPurposeIsOneDevanagariSentence(kind: PermissionKind) {
        let text = kind.purpose(.hindi)
        #expect(!text.isEmpty)
        #expect(text.hasSuffix("।"))
        #expect(text.filter { "।.!?".contains($0) }.count == 1)
        #expect(text.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) })
        #expect(kind.title(.hindi).unicodeScalars.contains { (0x0900...0x097F).contains($0.value) })
    }

    @Test func languageCodeMapping() {
        #expect(PermissionCopyLanguage(code: "hi") == .hindi)
        #expect(PermissionCopyLanguage(code: "hinglish") == .hindi)
        #expect(PermissionCopyLanguage(code: "en") == .english)
        #expect(PermissionCopyLanguage(code: nil) == .english)
    }

    @Test func statusHelpers() {
        #expect(PermissionStatus.granted.allowsUse && PermissionStatus.limited.allowsUse)
        #expect(!PermissionStatus.denied.allowsUse)
        #expect(PermissionStatus.notDetermined.canRequest)
        #expect(PermissionStatus.denied.needsSettings)
        #expect(!PermissionStatus.restricted.needsSettings)
    }
}
