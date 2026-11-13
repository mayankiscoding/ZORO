import Foundation
import Testing
import ZoroCore
@testable import SystemFeatures

@MainActor
@Suite("Security and privacy view model")
struct SecurityTests {
    func make(state: SecurityState = securityState(), identity: FakeIdentity = FakeIdentity()) -> (SecurityViewModel, FakeAPI, FakeIdentity) {
        let api = FakeAPI()
        let current = Locked(state)
        api.securityStateHandler = { current.get }
        api.setPrivacyModeHandler = { update in current.withLock { $0.privacyMode = update.mode } }
        api.setKillSwitchHandler = { update in current.withLock { $0.killSwitch = update.enabled } }
        api.setPermissionHandler = { key, update in
            current.withLock { s in
                if let i = s.permissions.firstIndex(where: { $0.key == key }) { s.permissions[i].granted = update.granted }
            }
        }
        api.revokeDeviceHandler = { id, _ in
            current.withLock { s in
                if let i = s.devices.firstIndex(where: { $0.deviceId == id }) { s.devices[i].revoked = true }
            }
        }
        let vm = SecurityViewModel(api: api, identity: identity, keys: FakeKeys(), biometrics: FakeBiometrics(), now: { t0 })
        return (vm, api, identity)
    }

    // MARK: states

    @Test func loadShowsStateAndSessionInfo() async {
        let (vm, _, _) = make()
        await vm.load()
        #expect(vm.phase == .loaded)
        #expect(vm.privacyMode == .strictPrivate)
        #expect(vm.session?.deviceId == "dev_me")
        #expect(vm.session?.keyProtectionText.contains("Secure Enclave") == true)
        #expect(vm.session?.biometryText == "Face ID is ready.")
        #expect(vm.session?.expiryText(now: t0).contains("ends") == true)
        #expect(vm.devices.first { $0.isThisDevice }?.id == "dev_me")
        #expect(vm.cloudPermissions.map(\.key) == ["cloud.sensitive"])
        #expect(vm.otherPermissions.map(\.key) == ["finance.read"])
    }

    @Test func disconnectedAndErrorStates() async {
        let api = FakeAPI()
        api.securityStateHandler = { throw ZoroError.transport("x") }
        let vm = SecurityViewModel(api: api, identity: FakeIdentity(), keys: FakeKeys(), biometrics: FakeBiometrics())
        await vm.load()
        #expect(vm.phase.isDisconnected)
        api.securityStateHandler = { throw ZoroError.http(status: 500, body: nil) }
        await vm.load()
        #expect(vm.phase.failure != nil)
        #expect(!vm.phase.isDisconnected)
    }

    // MARK: privacy mode

    @Test func looseningNeedsAConfirmationThenAProof() async {
        let (vm, api, identity) = make()
        await vm.load()
        await vm.requestPrivacyMode(.cloudIntelligence)
        #expect(vm.pendingPrivacyChange == .cloudIntelligence)
        #expect(api.calls.get.filter { $0.hasPrefix("setPrivacyMode") }.isEmpty, "nothing is sent before the owner confirms")
        await vm.confirmPrivacyChange()
        #expect(identity.signed.get == [.setPrivacyMode(.cloudIntelligence)])
        #expect(api.calls.get.contains("setPrivacyMode:cloud_intelligence"))
        #expect(vm.privacyMode == .cloudIntelligence)
        #expect(vm.notice == .success("Cloud intelligence is on."))
    }

    @Test func looseningWithoutAProofIsRefusedAndTheModeStays() async {
        let identity = FakeIdentity()
        identity.proofError = ZoroError.authenticationFailed("no match")
        let (vm, api, _) = make(identity: identity)
        await vm.load()
        await vm.requestPrivacyMode(.cloudIntelligence)
        await vm.confirmPrivacyChange()
        #expect(api.calls.get.filter { $0.hasPrefix("setPrivacyMode") }.isEmpty)
        #expect(vm.privacyMode == .strictPrivate)
        #expect(vm.notice?.kind == .failure)
        #expect(vm.notice?.text.contains("Face ID didn't match") == true)
    }

    @Test func cancelledProofPromptIsSilentAndNothingChanges() async {
        let identity = FakeIdentity()
        identity.proofError = ZoroError.userCancelled
        let (vm, api, _) = make(identity: identity)
        await vm.load()
        await vm.requestPrivacyMode(.cloudIntelligence)
        await vm.confirmPrivacyChange()
        #expect(api.calls.get.filter { $0.hasPrefix("setPrivacyMode") }.isEmpty)
        #expect(vm.notice == nil)
        #expect(vm.privacyMode == .strictPrivate)
    }

    @Test func cancellingTheExplanationSendsNothing() async {
        let (vm, api, identity) = make()
        await vm.load()
        await vm.requestPrivacyMode(.cloudIntelligence)
        vm.cancelPrivacyChange()
        await vm.confirmPrivacyChange()
        #expect(identity.signed.get.isEmpty)
        #expect(api.calls.get.filter { $0.hasPrefix("setPrivacyMode") }.isEmpty)
    }

    @Test func tighteningAppliesAtOnceAndIsStillSigned() async {
        let (vm, _, identity) = make(state: securityState(mode: .cloudIntelligence))
        await vm.load()
        await vm.requestPrivacyMode(.strictPrivate)
        #expect(vm.pendingPrivacyChange == nil)
        #expect(identity.signed.get == [.setPrivacyMode(.strictPrivate)])
        #expect(vm.privacyMode == .strictPrivate)
        #expect(vm.notice == .success("Private mode is on."))
    }

    @Test func serverRefusalKeepsTheModeAndSaysSo() async {
        let (vm, api, _) = make()
        api.setPrivacyModeHandler = { _ in throw ZoroError.http(status: 403, body: ErrorBody(code: "forbidden", message: "Proof rejected")) }
        await vm.load()
        await vm.requestPrivacyMode(.cloudIntelligence)
        await vm.confirmPrivacyChange()
        #expect(vm.privacyMode == .strictPrivate)
        #expect(vm.notice?.text.contains("Proof rejected.") == true)
    }

    @Test func requestingTheCurrentModeDoesNothing() async {
        let (vm, _, identity) = make()
        await vm.load()
        await vm.requestPrivacyMode(.strictPrivate)
        #expect(vm.pendingPrivacyChange == nil)
        #expect(identity.signed.get.isEmpty)
    }

    @Test func privacyCopyExplainsEachMode() {
        #expect(PrivacyCopy.line(.strictPrivate) == "Nothing leaves your ZORO server.")
        #expect(PrivacyCopy.line(.cloudIntelligence) == "Only what you allowed is sent out, with personal details removed.")
        #expect(PrivacyCopy.isLoosening(from: .strictPrivate, to: .cloudIntelligence))
        #expect(!PrivacyCopy.isLoosening(from: .cloudIntelligence, to: .strictPrivate))
        #expect(PrivacyCopy.explanation(.cloudIntelligence).contains("remove"))
    }

    // MARK: kill switch

    @Test func killSwitchIsSignedAndApplied() async {
        let (vm, _, identity) = make()
        await vm.load()
        await vm.setKillSwitch(true)
        #expect(identity.signed.get == [.setKillSwitch(true)])
        #expect(vm.killSwitchOn)
        #expect(vm.notice == .success("ZORO is paused."))
        await vm.setKillSwitch(false)
        #expect(!vm.killSwitchOn)
        #expect(vm.notice == .success("ZORO is running again."))
    }

    @Test func killSwitchWithoutAProofChangesNothing() async {
        let identity = FakeIdentity()
        identity.id = nil  // not paired: no proof possible
        let (vm, api, _) = make(identity: identity)
        await vm.load()
        await vm.setKillSwitch(true)
        #expect(api.calls.get.filter { $0.hasPrefix("setKillSwitch") }.isEmpty)
        #expect(!vm.killSwitchOn)
        #expect(vm.notice?.kind == .failure)
    }

    // MARK: permissions

    @Test func permissionChangeIsSignedWithTheKeyAndValue() async {
        let (vm, api, identity) = make()
        await vm.load()
        let grant = vm.cloudPermissions[0]
        await vm.setPermission(grant, granted: true)
        #expect(identity.signed.get == [.setPermission(key: "cloud.sensitive", granted: true)])
        #expect(api.calls.get.contains("setPermission:cloud.sensitive=true"))
        #expect(vm.cloudPermissions[0].granted)
        #expect(vm.busyPermissionKeys.isEmpty)
    }

    @Test func permissionWithoutProofOrOnServerFailureStaysAsItWas() async {
        let identity = FakeIdentity()
        identity.proofError = ZoroError.signingFailed("no key")
        let (vm, api, _) = make(identity: identity)
        await vm.load()
        await vm.setPermission(vm.cloudPermissions[0], granted: true)
        #expect(api.calls.get.filter { $0.hasPrefix("setPermission") }.isEmpty)
        #expect(!vm.cloudPermissions[0].granted)

        identity.proofError = nil
        api.setPermissionHandler = { _, _ in throw ZoroError.timeout }
        await vm.setPermission(vm.cloudPermissions[0], granted: true)
        #expect(!vm.cloudPermissions[0].granted)
        #expect(vm.notice?.kind == .failure)
    }

    // MARK: devices

    @Test func revokeNeedsAConfirmationThenAProof() async {
        let (vm, api, identity) = make()
        await vm.load()
        let mac = vm.devices.first { $0.id == "dev_mac" }!.info
        await vm.confirmRevoke()  // nothing pending
        #expect(api.calls.get.filter { $0.hasPrefix("revokeDevice") }.isEmpty)
        vm.requestRevoke(mac)
        #expect(vm.pendingRevoke == mac)
        await vm.confirmRevoke()
        #expect(identity.signed.get == [.revokeDevice(id: "dev_mac")])
        #expect(vm.devices.map(\.id) == ["dev_me"])
        #expect(vm.removedDevices.map(\.deviceId) == ["dev_mac"])
        #expect(vm.notice == .success("Removed My Mac."))
    }

    @Test func revokeWithoutAProofRemovesNothing() async {
        let identity = FakeIdentity()
        identity.proofError = ZoroError.userCancelled
        let (vm, api, _) = make(identity: identity)
        await vm.load()
        vm.requestRevoke(vm.devices[1].info)
        await vm.confirmRevoke()
        #expect(api.calls.get.filter { $0.hasPrefix("revokeDevice") }.isEmpty)
        #expect(vm.devices.count == 2)
    }
}

@MainActor
@Suite("Audit log view model")
struct AuditLogTests {
    func pagedAPI(pages: [String?: Page<AuditRecord>]) -> FakeAPI {
        let api = FakeAPI()
        api.auditHandler = { cursor, _ in
            guard let page = pages[cursor] else { throw ZoroError.http(status: 404, body: nil) }
            return page
        }
        return api
    }

    @Test func firstPageThenLoadMoreAppends() async {
        let api = pagedAPI(pages: [
            nil: Page(items: [audit("1"), audit("2")], nextCursor: "c2"),
            "c2": Page(items: [audit("3")], nextCursor: nil),
        ])
        let vm = AuditLogViewModel(api: api, pageSize: 2)
        await vm.load()
        #expect(vm.phase == .loaded)
        #expect(vm.records.map(\.id) == ["1", "2"])
        #expect(vm.hasMore)
        await vm.loadMore()
        #expect(vm.records.map(\.id) == ["1", "2", "3"])
        #expect(!vm.hasMore)
        await vm.loadMore()  // nothing more: no extra request
        #expect(api.calls.get == ["auditLog:-", "auditLog:c2"])
    }

    @Test func aRepeatedCursorEndsPaginationInsteadOfLooping() async {
        let api = pagedAPI(pages: [
            nil: Page(items: [audit("1")], nextCursor: "c2"),
            "c2": Page(items: [audit("2")], nextCursor: "c2"),
        ])
        let vm = AuditLogViewModel(api: api)
        await vm.load()
        await vm.loadMore()
        #expect(vm.records.map(\.id) == ["1", "2"])
        #expect(!vm.hasMore)
    }

    @Test func loadMoreFailureKeepsTheListAndRetryWorks() async {
        let attempts = Locked(0)
        let api = FakeAPI()
        api.auditHandler = { cursor, _ in
            if cursor == nil { return Page(items: [audit("1")], nextCursor: "c2") }
            if attempts.withLock({ $0 += 1; return $0 }) == 1 { throw ZoroError.timeout }
            return Page(items: [audit("2")], nextCursor: nil)
        }
        let vm = AuditLogViewModel(api: api)
        await vm.load()
        await vm.loadMore()
        #expect(vm.records.count == 1)
        #expect(vm.loadMoreFailure == SystemCopy.unreachable)
        #expect(vm.hasMore)
        await vm.loadMore()
        #expect(vm.records.count == 2)
        #expect(vm.loadMoreFailure == nil)
    }

    @Test func emptyDisconnectedAndErrorStates() async {
        let api = FakeAPI()
        api.auditHandler = { _, _ in Page(items: [], nextCursor: nil) }
        let vm = AuditLogViewModel(api: api)
        await vm.load()
        #expect(vm.phase == .empty)
        api.auditHandler = { _, _ in throw ZoroError.transport("x") }
        await vm.load()
        #expect(vm.phase.isDisconnected)
        api.auditHandler = { _, _ in throw ZoroError.http(status: 500, body: nil) }
        await vm.load()
        #expect(vm.phase.failure != nil && !vm.phase.isDisconnected)
    }

    @Test func decisionFilterWorksOnLoadedRecords() async {
        let api = pagedAPI(pages: [nil: Page(items: [audit("1", decision: .allowed), audit("2", decision: .denied)], nextCursor: nil)])
        let vm = AuditLogViewModel(api: api)
        await vm.load()
        vm.decisionFilter = .denied
        #expect(vm.visibleRecords.map(\.id) == ["2"])
        #expect(AuditCopy.decisionLabel(.denied) == "Denied")
        #expect(AuditCopy.actionTitle("policy.tool_decision") == "Policy tool decision")
    }

    @Test func pageSizeIsClamped() async {
        let api = pagedAPI(pages: [nil: Page(items: [], nextCursor: nil)])
        let seen = Locked<Int?>(nil)
        api.auditHandler = { _, limit in seen.withLock { $0 = limit }; return Page(items: [], nextCursor: nil) }
        let vm = AuditLogViewModel(api: api, pageSize: 5000)
        await vm.load()
        #expect(seen.get == 200)
    }
}
