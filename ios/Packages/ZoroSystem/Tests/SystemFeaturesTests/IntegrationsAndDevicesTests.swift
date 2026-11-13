import Foundation
import Testing
import ZoroCore
@testable import SystemFeatures

func cap(_ id: String, _ status: CapabilityStatus, title: String? = nil, domain: String = "shopping", note: String = "", level: IntegrationLevel? = nil, requires: [String] = []) -> Capability {
    Capability(id: id, title: title ?? id.capitalized, domain: domain, status: status, integrationLevel: level, requires: requires, note: note)
}

@Suite("Integrations")
struct IntegrationGroupingTests {
    @Test func everyStatusMapsToOneOfTheSixPlainGroups() {
        let expected: [CapabilityStatus: IntegrationGroup] = [
            .workingNative: .working, .workingLocal: .working, .workingIntegration: .working,
            .requiresCredentials: .needsCredentials, .requiresPartnership: .needsPartnerAgreement,
            .manualUserStep: .needsTap, .restrictedByIos: .notAllowedByIOS, .unavailable: .notAvailable,
        ]
        #expect(expected.count == CapabilityStatus.allCases.count)
        for status in CapabilityStatus.allCases { #expect(IntegrationGroup(status: status) == expected[status]) }
    }

    @Test func groupTitlesAreThePlainLabels() {
        #expect(IntegrationGroup.allCases.map(\.title) == [
            "Working", "Needs a tap from you", "Needs your credentials", "Needs a partner agreement", "Not allowed by iOS", "Not available",
        ])
    }

    @Test func sectionsFollowGroupOrderOmitEmptyGroupsAndSortByTitle() {
        let items = IntegrationGrouping.merge(
            server: [cap("b", .requiresCredentials, title: "Spotify"), cap("a", .workingLocal, title: "Zeta"), cap("c", .workingNative, title: "Alpha"), cap("d", .unavailable, title: "Bank")],
            device: [])
        let sections = IntegrationGrouping.sections(items)
        #expect(sections.map(\.group) == [.working, .needsCredentials, .notAvailable])
        #expect(sections[0].items.map(\.title) == ["Alpha", "Zeta"])
    }

    @Test func mergeKeepsTheMoreRestrictiveStatusAndRecordsBothSources() {
        let server = [cap("music.play", .workingIntegration, title: "Play music", domain: "music", requires: ["SPOTIFY_CLIENT_ID"])]
        let device = [cap("music.play", .restrictedByIos, title: "play", domain: "device", note: "Needs Apple Music access")]
        let merged = IntegrationGrouping.merge(server: server, device: device)
        #expect(merged.count == 1)
        #expect(merged[0].group == .notAllowedByIOS)
        #expect(merged[0].title == "Play music", "the server's title is kept")
        #expect(merged[0].sources == [.server, .device])
        #expect(merged[0].note == "Needs Apple Music access")
        #expect(merged[0].requires == ["SPOTIFY_CLIENT_ID"])
    }

    @Test func mergeNeverUpgradesAServerLimit() {
        let merged = IntegrationGrouping.merge(
            server: [cap("x", .requiresCredentials)], device: [cap("x", .workingNative)])
        #expect(merged[0].group == .needsCredentials)
    }

    @Test func deviceOnlyCapabilitiesAreListed() {
        let merged = IntegrationGrouping.merge(server: [], device: [cap("device.set_timer", .workingNative, domain: "device")])
        #expect(merged.map(\.id) == ["device.set_timer"])
        #expect(merged[0].sources == [.device])
    }

    @Test func filtersByDomainAndSearch() {
        let items = IntegrationGrouping.merge(
            server: [cap("a", .workingLocal, title: "Groceries", domain: "shopping"), cap("b", .workingLocal, title: "Playlists", domain: "music")], device: [])
        #expect(IntegrationGrouping.sections(items, domain: "music").flatMap(\.items).map(\.id) == ["b"])
        #expect(IntegrationGrouping.sections(items, search: "groc").flatMap(\.items).map(\.id) == ["a"])
        #expect(IntegrationGrouping.sections(items, domain: "music", search: "groc").isEmpty)
    }

    @Test func executorRegistryListsSupportedToolsAsWorkingOnThisDevice() async {
        let registry = ExecutorCapabilityRegistry(executor: FakeExecutor(tools: ["device.set_timer", "device.create_reminder"]))
        let caps = await registry.capabilities()
        #expect(caps.map(\.id) == ["device.create_reminder", "device.set_timer"])
        #expect(caps.allSatisfy { $0.status == .workingNative })
        #expect(caps[0].title == "Create reminder")
    }
}

@MainActor
@Suite("Integrations view model")
struct IntegrationsViewModelTests {
    @Test func loadGroupsServerCapabilities() async {
        let api = FakeAPI()
        api.capabilitiesHandler = { [cap("a", .workingLocal), cap("b", .requiresPartnership)] }
        let vm = IntegrationsViewModel(api: api)
        #expect(vm.phase == .idle)
        await vm.load()
        #expect(vm.phase == .loaded)
        #expect(vm.sections.map(\.group) == [.working, .needsPartnerAgreement])
        #expect(vm.summary == "1 of 2 working.")
    }

    @Test func loadMergesTheInjectedDeviceRegistry() async {
        let api = FakeAPI()
        api.capabilitiesHandler = { [cap("a", .workingLocal, domain: "shopping")] }
        let vm = IntegrationsViewModel(api: api, deviceRegistry: ExecutorCapabilityRegistry(executor: FakeExecutor(tools: ["device.set_timer"])))
        await vm.load()
        #expect(vm.items.count == 2)
        #expect(vm.domains == ["device", "shopping"])
    }

    @Test func emptyRegistryIsEmptyWithASentence() async {
        let api = FakeAPI()
        api.capabilitiesHandler = { [] }
        let vm = IntegrationsViewModel(api: api)
        await vm.load()
        #expect(vm.phase == .empty)
        #expect(vm.emptyMessage.contains("server"))
    }

    @Test func serverDownWithoutDeviceRegistryIsDisconnected() async {
        let api = FakeAPI()
        api.capabilitiesHandler = { throw ZoroError.transport("down") }
        let vm = IntegrationsViewModel(api: api)
        await vm.load()
        #expect(vm.phase.isDisconnected)
    }

    @Test func serverDownStillShowsWhatThisDeviceCanDo() async {
        let api = FakeAPI()
        api.capabilitiesHandler = { throw ZoroError.transport("down") }
        let vm = IntegrationsViewModel(api: api, deviceRegistry: ExecutorCapabilityRegistry(executor: FakeExecutor(tools: ["device.set_timer"])))
        await vm.load()
        #expect(vm.phase == .loaded)
        #expect(vm.serverNote?.contains("only what this device can do") == true)
        #expect(vm.items.count == 1)
    }

    @Test func serverErrorIsFailed() async {
        let api = FakeAPI()
        api.capabilitiesHandler = { throw ZoroError.http(status: 500, body: nil) }
        let vm = IntegrationsViewModel(api: api)
        await vm.load()
        #expect(vm.phase.failure != nil)
        #expect(!vm.phase.isDisconnected)
    }

    @Test func filterWithNoMatchKeepsLoadedPhaseAndShowsTheMismatchSentence() async {
        let api = FakeAPI()
        api.capabilitiesHandler = { [cap("a", .workingLocal, title: "Groceries")] }
        let vm = IntegrationsViewModel(api: api)
        await vm.load()
        vm.searchText = "zzz"
        #expect(vm.sections.isEmpty)
        #expect(vm.emptyMessage.contains("Clear the filter"))
    }
}

@MainActor
@Suite("Device control view model")
struct DeviceControlTests {
    func make(tools: [String] = ["device.set_timer"], kill: Bool = false, actions: [DeviceQuickAction] = DeviceQuickAction.suggested) -> (DeviceControlViewModel, FakeAPI, FakeExecutor) {
        let api = FakeAPI()
        api.securityStateHandler = { securityState(kill: kill) }
        api.capabilitiesHandler = { [cap("music.dnd", .restrictedByIos, title: "Change Focus modes", note: "iOS has no API for this.")] }
        let executor = FakeExecutor(tools: tools)
        let vm = DeviceControlViewModel(api: api, identity: FakeIdentity(), executor: executor, quickActions: actions, now: { t0 })
        return (vm, api, executor)
    }

    @Test func loadShowsDevicesWithOnlineStateThisDeviceFirst() async {
        let (vm, _, _) = make()
        await vm.load()
        #expect(vm.phase == .loaded)
        #expect(vm.devices.map(\.id) == ["dev_me", "dev_mac"])
        #expect(vm.devices[0].isThisDevice)
        #expect(vm.devices[0].statusText(now: t0) == "Online")
        #expect(vm.devices[1].statusText(now: t0.addingTimeInterval(600)).hasPrefix("Offline, last seen"))
    }

    @Test func revokedDevicesAreNotListed() async {
        let api = FakeAPI()
        api.securityStateHandler = { securityState(devices: [device("dev_me"), device("dev_old", revoked: true)]) }
        let vm = DeviceControlViewModel(api: api, identity: FakeIdentity(), executor: FakeExecutor())
        await vm.load()
        #expect(vm.devices.map(\.id) == ["dev_me"])
    }

    @Test func noDevicesIsEmpty() async {
        let api = FakeAPI()
        api.securityStateHandler = { securityState(devices: []) }
        let vm = DeviceControlViewModel(api: api, identity: FakeIdentity(), executor: FakeExecutor())
        await vm.load()
        #expect(vm.phase == .empty)
        #expect(vm.emptyMessage.contains("Pair"))
    }

    @Test func disconnectedStillShowsQuickActionsState() async {
        let api = FakeAPI()
        api.securityStateHandler = { throw ZoroError.transport("x") }
        let vm = DeviceControlViewModel(api: api, identity: FakeIdentity(), executor: FakeExecutor(tools: ["device.set_timer"]))
        await vm.load()
        #expect(vm.phase.isDisconnected)
        #expect(vm.quickActions.allSatisfy { $0.isAvailable })
    }

    @Test func restrictedListHasTheStandardItemsPlusServerRestrictions() async {
        let (vm, _, _) = make()
        await vm.load()
        #expect(vm.restricted.count == RestrictedActions.standard.count + 1)
        #expect(vm.restricted.last?.title == "Change Focus modes")
        #expect(vm.restricted.first?.explanation.contains("WhatsApp") == true)
    }

    @Test func quickActionsAreUnavailableWhenTheDeviceDoesNotSupportTheTool() async {
        let (vm, _, _) = make(tools: [])
        await vm.load()
        #expect(vm.quickActions.allSatisfy { !$0.isAvailable })
        #expect(vm.quickActions[0].unavailableReason == "This device can't do that yet.")
    }

    @Test func quickActionsStopWhileTheKillSwitchIsOn() async {
        let (vm, _, executor) = make(kill: true)
        await vm.load()
        #expect(vm.killSwitchOn)
        await vm.run(vm.quickActions[0].action)
        #expect(executor.executed.get.isEmpty)
        #expect(vm.notice == .failure(SystemCopy.killSwitchOn))
    }

    @Test func lowRiskRunsAtOnceThroughTheExecutor() async {
        let (vm, _, executor) = make()
        await vm.load()
        await vm.run(vm.quickActions[0].action)
        let request = executor.executed.get.first
        #expect(request?.tool == "device.set_timer")
        #expect(request?.targetDeviceId == "dev_me")
        #expect(request?.requiresUserConfirmation == false)
        #expect(request?.expiresAt == t0.addingTimeInterval(60))
        #expect(vm.notice == .success("Done. Set a 10 minute timer."))
        #expect(vm.runningActionId == nil)
    }

    @Test func mediumRiskWaitsForConfirmation() async {
        let medium = DeviceQuickAction(id: "m", title: "Lock this Mac", symbol: "lock", tool: "mac.lock", risk: .medium)
        let (vm, _, executor) = make(tools: ["mac.lock"], actions: [medium])
        await vm.load()
        await vm.run(medium)
        #expect(executor.executed.get.isEmpty)
        #expect(vm.pendingConfirmation == medium)
        await vm.confirmPending()
        #expect(executor.executed.get.count == 1)
        #expect(executor.executed.get.first?.requiresUserConfirmation == true)
        #expect(vm.pendingConfirmation == nil)
    }

    @Test func cancellingTheConfirmationRunsNothing() async {
        let medium = DeviceQuickAction(id: "m", title: "Lock this Mac", symbol: "lock", tool: "mac.lock", risk: .medium)
        let (vm, _, executor) = make(tools: ["mac.lock"], actions: [medium])
        await vm.load()
        await vm.run(medium)
        vm.cancelPending()
        await vm.confirmPending()
        #expect(executor.executed.get.isEmpty)
    }

    @Test func highRiskIsNeverAQuickAction() async {
        let high = DeviceQuickAction(id: "h", title: "Wipe", symbol: "trash", tool: "mac.wipe", risk: .high)
        let (vm, _, executor) = make(tools: ["mac.wipe"], actions: [high])
        await vm.load()
        #expect(vm.quickActions[0].unavailableReason == "This needs your approval, so ask ZORO instead.")
        await vm.run(high)
        #expect(executor.executed.get.isEmpty)
        #expect(vm.pendingConfirmation == nil)
    }

    @Test func failedResultsExplainWhatToDo() async {
        let (vm, _, executor) = make()
        executor.result = { request in .failure(request, code: .permissionDenied, capabilityStatus: .requiresCredentials) }
        await vm.load()
        await vm.run(vm.quickActions[0].action)
        #expect(vm.notice == .failure("ZORO needs permission for this. Allow it in Settings, then try again."))
    }

    @Test func unknownActionIsRefused() async {
        let (vm, _, executor) = make()
        await vm.load()
        await vm.run(DeviceQuickAction(id: "zzz", title: "Nope", symbol: "x", tool: "device.set_timer"))
        #expect(executor.executed.get.isEmpty)
        #expect(vm.notice?.kind == .failure)
    }
}

@Suite("Device action error text")
struct DeviceActionErrorTextTests {
    @MainActor @Test func invalidArgumentsHasItsOwnPlainSentence() {
        let result = DeviceActionResult(actionId: "a", ok: false, errorCode: "invalid_arguments", errorMessage: "`time` must be HH:MM", executedAt: t0)
        let text = DeviceControlViewModel.failureText(result)
        #expect(text == "ZORO sent this device something it could not use. Nothing was changed.")
        #expect(!text.contains("`"))
    }
}
