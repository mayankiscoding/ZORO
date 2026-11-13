import Testing
@testable import PermissionManager

@MainActor
@Suite struct PermissionCenterTests {
    @Test func startsNotDeterminedAndUnsupportedWithoutProvider() {
        let center = PermissionCenter(providers: [FakePermissionProvider(.photos, status: .granted)])
        #expect(center.status(for: .photos) == .notDetermined)
        #expect(center.status(for: .alarms) == .unsupported)
    }

    @Test func refreshAllReadsEveryProviderWithoutRequesting() async {
        let photos = FakePermissionProvider(.photos, status: .limited)
        let mic = FakePermissionProvider(.microphone, status: .denied)
        let center = PermissionCenter(providers: [photos, mic])
        await center.refreshAll()
        #expect(center.status(for: .photos) == .limited)
        #expect(center.status(for: .microphone) == .denied)
        #expect(center.isUsable(.photos))
        #expect(!center.isUsable(.microphone))
        #expect(await photos.requestCount == 0)
        #expect(await mic.requestCount == 0)
    }

    @Test func requestAsksOnlyWhenNotDetermined() async {
        let provider = FakePermissionProvider(.contacts, status: .notDetermined, answers: .granted)
        let center = PermissionCenter(providers: [provider])
        let first = await center.request(.contacts)
        #expect(first.status == .granted)
        #expect(first.prompted)
        #expect(first.isUsable)
        let second = await center.request(.contacts)
        #expect(second.status == .granted)
        #expect(!second.prompted)
        #expect(await provider.requestCount == 1)
    }

    @Test func deniedIsNeverReaskedAndPointsToSettings() async {
        let provider = FakePermissionProvider(.location, status: .denied)
        let center = PermissionCenter(providers: [provider])
        let outcome = await center.request(.location)
        #expect(outcome.status == .denied)
        #expect(!outcome.prompted)
        #expect(outcome.needsSettings)
        #expect(await provider.requestCount == 0)
        #expect(center.prompt(for: .location).action == .openSettings)
    }

    @Test func ownerRefusingTheSheetIsReportedAsDenied() async {
        let provider = FakePermissionProvider(.calendars, status: .notDetermined, answers: .denied)
        let center = PermissionCenter(providers: [provider])
        let outcome = await center.request(.calendars)
        #expect(outcome.status == .denied)
        #expect(outcome.prompted)
        #expect(!outcome.isUsable)
        #expect(center.status(for: .calendars) == .denied)
    }

    @Test func limitedAccessIsUsable() async {
        let provider = FakePermissionProvider(.photos, status: .notDetermined, answers: .limited)
        let center = PermissionCenter(providers: [provider])
        let outcome = await center.request(.photos)
        #expect(outcome.status == .limited)
        #expect(outcome.isUsable)
    }

    @Test func missingProviderAndUnsupportedNeverPrompt() async {
        let center = PermissionCenter(providers: [UnsupportedPermissionProvider(.alarms)])
        let alarms = await center.request(.alarms)
        #expect(alarms.status == .unsupported)
        #expect(!alarms.prompted)
        let music = await center.request(.music)
        #expect(music.status == .unsupported)
        #expect(center.prompt(for: .alarms).action == .none)
    }

    @Test func concurrentRequestsShareOneSystemCall() async {
        let provider = FakePermissionProvider(.microphone, status: .notDetermined, answers: .granted, delayNanos: 50_000_000)
        let center = PermissionCenter(providers: [provider])
        async let a = center.request(.microphone)
        async let b = center.request(.microphone)
        let (ra, rb) = await (a, b)
        #expect(ra.status == .granted && rb.status == .granted)
        #expect(await provider.requestCount == 1)
    }

    @Test func requestAllStopsAtFirstRefusal() async {
        let mic = FakePermissionProvider(.microphone, status: .notDetermined, answers: .denied)
        let speech = FakePermissionProvider(.speechRecognition, status: .notDetermined, answers: .granted)
        let center = PermissionCenter(providers: [mic, speech])
        let outcomes = await center.request(all: [.microphone, .speechRecognition])
        #expect(outcomes.count == 1)
        #expect(await speech.requestCount == 0)
    }

    @Test func requestAllSkipsOverUnsupportedKinds() async {
        let notifications = FakePermissionProvider(.notifications, status: .notDetermined, answers: .granted)
        let center = PermissionCenter(providers: [UnsupportedPermissionProvider(.alarms), notifications])
        let outcomes = await center.request(all: [.alarms, .notifications])
        #expect(outcomes.map(\.status) == [.unsupported, .granted])
    }

    @Test func refreshPicksUpAChangeMadeInSettings() async {
        let provider = FakePermissionProvider(.reminders, status: .denied)
        let center = PermissionCenter(providers: [provider])
        await center.refresh(.reminders)
        #expect(center.status(for: .reminders) == .denied)
        await provider.setStatus(.granted)
        await center.refresh(.reminders)
        #expect(center.status(for: .reminders) == .granted)
    }

    @Test func promptCarriesPurposeInTheChosenLanguage() {
        let center = PermissionCenter(providers: [FakePermissionProvider(.photos, status: .notDetermined)], language: .hindi)
        let hindi = center.prompt(for: .photos)
        #expect(hindi.action == .requestAccess)
        #expect(hindi.purpose == PermissionKind.photos.hindiPurpose)
        center.language = .english
        #expect(center.prompt(for: .photos).purpose == PermissionKind.photos.englishPurpose)
        #expect(center.purpose(for: .photos) == PermissionKind.photos.englishPurpose)
    }
}
