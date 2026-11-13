import Foundation
import Testing
@testable import NativeActionBroker
import ZoroCore

struct Rig {
    let calendar = FakeCalendarStore()
    let contacts = FakeContactsStore()
    let notifications = FakeNotifications()
    let opener = RecordingOpener()
    let shortcuts = FakeShortcuts()
    let alarms = FakeAlarms()
    let composer = FakeComposer()
    let process = FakeProcessRunner()

    var common: [any DeviceActionHandler] {
        [
            CalendarHandler(store: calendar, timeZone: TimeZone(identifier: "Asia/Kolkata")!, now: { fixedNow }),
            ContactsHandler(store: contacts),
            NotificationHandler(scheduler: notifications, now: { fixedNow }, makeId: { "n-1" }),
            LocationHandler(provider: FakeLocation()),
            OpenURLHandler(opener: opener),
            ShortcutHandler(runner: shortcuts),
            WhatsAppComposeHandler(opener: opener),
        ]
    }

    func phone(confirmer: (any DeviceActionConfirming)? = nil) -> NativeActionBroker {
        NativeActionBroker(
            platform: .ios,
            handlers: common + [
                AlarmHandler(scheduler: alarms), MessageComposeHandler(composer: composer), HomeSceneHandler(runner: FakeHome()),
            ],
            confirmer: confirmer, now: { fixedNow })
    }

    func mac(folders: [ApprovedFolder] = []) -> NativeActionBroker {
        NativeActionBroker(
            platform: .macos,
            handlers: common + [
                AppleScriptHandler(runner: OSAScriptRunner(runner: process)),
                FileHandler(folders: ApprovedFolderList(folders), searcher: SpotlightFileSearcher(runner: process), opener: opener),
            ],
            confirmer: nil, now: { fixedNow })
    }
}

let start = "2026-11-08T09:00:00+05:30"

/// Valid arguments for every tool this target handles.
let validCalls: [(String, JSONObject)] = [
    ("device.reminder.create", ["title": "Pay electricity bill", "due_at": "2026-11-09T18:00:00+05:30"]),
    ("device.calendar.create_event", ["title": "Dentist", "start_at": .string(start), "location": "Indiranagar"]),
    ("device.calendar.upcoming", ["limit": 3]),
    ("device.contacts.find", ["query": "Asha"]),
    ("device.contacts.save", ["given_name": "Ravi", "phone": "+91 98450 00000", "email": "ravi@example.com"]),
    ("device.notification.schedule", ["title": "Stretch", "body": "Time to stand up", "at": "2026-11-07T18:00:00+05:30"]),
    ("device.location.current", [:]),
    ("device.open_url", ["url": "https://www.apple.com/in/"]),
    ("device.shortcut.run", ["name": "Log water", "input": "250 ml"]),
    ("device.whatsapp.compose", ["phone": "+91 98765 43210", "text": "On my way"]),
]

let phoneOnlyCalls: [(String, JSONObject)] = [
    ("ios.alarm.create", ["time": "06:30", "label": "Run", "repeat_days": ["mon", "wed"]]),
    ("ios.timer.start", ["seconds": 300, "label": "Tea"]),
    ("ios.message.compose", ["recipients": ["+91 98765 43210"], "body": "Reached"]),
    ("ios.home.run_scene", ["scene_name": "Good night"]),
]

@Suite struct DispatchTests {
    @Test func everyCommonToolSucceedsOnBothPlatforms() async {
        let rig = Rig()
        await rig.calendar.setStored([
            CalendarEventInfo(id: "e1", title: "Standup", startAt: fixedNow.addingTimeInterval(3600), endAt: fixedNow.addingTimeInterval(5400), location: nil, calendar: "Work")
        ])
        for broker in [rig.phone(), rig.mac()] {
            for (tool, args) in validCalls {
                let r = await broker.execute(request(tool, args))
                #expect(r.ok, "\(tool): \(r.errorMessage ?? "")")
                #expect(r.errorCode == nil)
            }
        }
        #expect(await rig.calendar.reminders.count == 2)
        #expect(await rig.notifications.scheduled.first?.id == "n-1")
    }

    @Test func phoneOnlyToolsSucceedOnPhone() async {
        let rig = Rig()
        let broker = rig.phone()
        for (tool, args) in phoneOnlyCalls {
            let r = await broker.execute(request(tool, args))
            #expect(r.ok, "\(tool): \(r.errorMessage ?? "")")
        }
        let alarm = await rig.alarms.alarms.first
        #expect(alarm?.hour == 6 && alarm?.minute == 30 && alarm?.repeatDays == [.mon, .wed])
        #expect(await rig.composer.composed.first?.0 == ["+919876543210"])
    }

    @Test func resultShapes() async throws {
        let rig = Rig()
        await rig.calendar.setStored([
            CalendarEventInfo(id: "e1", title: "Standup", startAt: fixedNow.addingTimeInterval(3600), endAt: fixedNow.addingTimeInterval(5400), location: "Room 4", calendar: "Work")
        ])
        let broker = rig.phone()
        let upcoming = await broker.execute(request("device.calendar.upcoming"))
        let event = try #require(upcoming.result?["events"]?.arrayValue?.first)
        #expect(event["title"] == "Standup")
        #expect(event["start_at"]?.stringValue?.hasSuffix("+05:30") == true)
        #expect(event["location"] == "Room 4")
        #expect(upcoming.capabilityStatus == .workingNative)

        let loc = await broker.execute(request("device.location.current"))
        #expect(loc.result?["place_ref"] == "geo:12.97159,77.59456;u=35")
        #expect(loc.result?["locality"] == "Bengaluru")
        #expect(loc.result?["accuracy_m"] == 35)

        let found = await broker.execute(request("device.contacts.find", ["query": "Asha"]))
        #expect(found.result?["matches"]?[0]?["contact_ref"] == "c1")

        let wa = await broker.execute(request("device.whatsapp.compose", ["text": "hi"]))
        #expect(wa.result == ["opened": true])
        #expect(wa.capabilityStatus == .manualUserStep)

        let timer = await broker.execute(request("ios.timer.start", ["seconds": 90]))
        #expect(timer.result?["timer_id"]?.stringValue?.isEmpty == false)
    }

    @Test func macOnlyToolsSucceedOnMac() async throws {
        let rig = Rig()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zoro-dispatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tax 2026.pdf")
        try Data("x".utf8).write(to: file)
        await rig.process.setOutput(ProcessOutput(status: 0, stdout: file.path + "\n"))
        let broker = rig.mac(folders: [ApprovedFolder(ref: "docs", url: dir, name: "Documents")])

        let script = await broker.execute(request("mac.applescript.run", ["script_id": "music.apple.pause"]))
        #expect(script.ok)
        let search = await broker.execute(request("mac.file.search", ["query": "tax"]))
        #expect(search.ok)
        let hit = try #require(search.result?["files"]?.arrayValue?.first)
        #expect(hit["path_ref"] == "docs:tax 2026.pdf")
        #expect(hit["name"] == "tax 2026.pdf")
        let open = await broker.execute(request("mac.file.open", ["path_ref": "docs:tax 2026.pdf"]))
        #expect(open.ok)
        #expect(await rig.opener.opened.last?.lastPathComponent == "tax 2026.pdf")
    }

    @Test func supportedToolsFollowPlatform() async {
        let rig = Rig()
        let phone = await rig.phone().supportedTools
        let mac = await rig.mac().supportedTools
        #expect(phone.contains("ios.alarm.create") && !phone.contains("mac.file.search"))
        #expect(mac.contains("mac.applescript.run") && !mac.contains("ios.alarm.create"))
        #expect(!phone.contains("device.photos.search"))
    }

    @Test func unknownAndWrongPlatformToolsAreUnsupported() async {
        let rig = Rig()
        let unknown = await rig.phone().execute(request("device.teleport", [:]))
        #expect(unknown.errorCode == "unsupported" && unknown.capabilityStatus == .unavailable)
        let macOnPhone = await rig.phone().execute(request("mac.applescript.run", ["script_id": "music.apple.play"]))
        #expect(macOnPhone.errorCode == "unsupported" && macOnPhone.capabilityStatus == .restrictedByIos)
        let phoneOnMac = await rig.mac().execute(request("ios.alarm.create", ["time": "07:00"]))
        #expect(phoneOnMac.errorCode == "unsupported" && phoneOnMac.capabilityStatus == .unavailable)
        let noHandler = await rig.phone().execute(request("device.photos.search", ["query": [:]]))
        #expect(noHandler.errorCode == "unsupported")
        let health = await rig.mac().execute(request("device.health.query", [:]))
        #expect(health.errorCode == "unsupported")
    }

    @Test func expiredRequestsDoNotRun() async {
        let rig = Rig()
        let r = await rig.phone().execute(request("device.reminder.create", ["title": "x"], expiresIn: -1))
        #expect(r.errorCode == "expired")
        #expect(await rig.calendar.reminders.isEmpty)
    }

    @Test func duplicateDeliveriesRunOnce() async {
        let state = CountingHandlerState()
        let broker = NativeActionBroker(platform: .ios, handlers: [CountingHandler(state: state)], confirmer: nil, now: { fixedNow })
        let req = request("device.open_url", ["url": "https://example.com"], id: "same")
        async let a = broker.execute(req)
        async let b = broker.execute(req)
        let (ra, rb) = await (a, b)
        let rc = await broker.execute(req)
        #expect(ra == rb && rb == rc)
        #expect(await state.runs == 1)
    }

    @Test func pluginHandlersCanBeRegistered() async {
        let state = CountingHandlerState()
        let broker = NativeActionBroker(platform: .macos, handlers: [], confirmer: nil, now: { fixedNow })
        #expect(await broker.supportedTools.isEmpty)
        await broker.register(CountingHandler(state: state))
        #expect(await broker.supportedTools == ["device.open_url"])
    }
}

@Suite struct ValidationTests {
    static let bad: [(String, JSONObject, String)] = [
        ("device.reminder.create", [:], "title"),
        ("device.reminder.create", ["title": "   "], "title"),
        ("device.reminder.create", ["title": 5], "title"),
        ("device.reminder.create", ["title": "x", "due_at": "tomorrow"], "due_at"),
        ("device.reminder.create", ["title": "x", "due_at": "2026-11-09T18:00:00"], "due_at"),
        ("device.calendar.create_event", ["title": "x"], "start_at"),
        ("device.calendar.create_event", ["title": "x", "start_at": .string(start), "end_at": "2026-11-08T08:00:00+05:30"], "end_at"),
        ("device.calendar.upcoming", ["limit": 0], "limit"),
        ("device.calendar.upcoming", ["limit": 2.5], "limit"),
        ("device.contacts.find", ["query": ""], "query"),
        ("device.contacts.save", ["given_name": "A", "phone": "call me"], "phone"),
        ("device.contacts.save", ["given_name": "A", "email": "not-an-email"], "email"),
        ("device.notification.schedule", ["title": "x"], "body"),
        ("device.notification.schedule", ["title": "x", "body": "y", "at": "2020-01-01T00:00:00Z"], "at"),
        ("device.open_url", ["url": "http://example.com"], "url"),
        ("device.shortcut.run", [:], "name"),
        ("device.whatsapp.compose", ["phone": "12", "text": "hi"], "phone"),
        ("device.whatsapp.compose", ["phone": "+91 98765 43210"], "text"),
        ("ios.alarm.create", ["time": "7:00"], "time"),
        ("ios.alarm.create", ["time": "24:00"], "time"),
        ("ios.alarm.create", ["time": "06:30", "repeat_days": ["monday"]], "repeat_days"),
        ("ios.timer.start", ["seconds": 0], "seconds"),
        ("ios.timer.start", [:], "seconds"),
        ("ios.message.compose", ["recipients": [], "body": "x"], "recipients"),
        ("ios.message.compose", ["recipients": ["mom"], "body": "x"], "recipients"),
        ("ios.home.run_scene", [:], "scene_name"),
    ]

    @Test func invalidArgumentsFailWithFieldName() async {
        let rig = Rig()
        let broker = rig.phone()
        for (tool, args, field) in Self.bad {
            let r = await broker.execute(request(tool, args))
            #expect(!r.ok, "\(tool) \(args)")
            #expect(r.errorCode == "invalid_arguments", "\(tool)")
            #expect(r.errorMessage?.hasPrefix("`\(field)`") == true, "\(tool): \(r.errorMessage ?? "")")
        }
        #expect(await rig.calendar.reminders.isEmpty)
        #expect(await rig.opener.opened.isEmpty)
    }

    @Test func controlCharactersAreRejected() throws {
        #expect(throws: DeviceActionError.self) { try ToolArguments(["t": "a\u{0}b"]).string("t") }
        #expect(try ToolArguments(["t": "line one\nline two"]).string("t") == "line one\nline two")
    }

    @Test func clockParsing() {
        #expect(DeviceTime.parseClock("00:00")! == (0, 0))
        #expect(DeviceTime.parseClock("23:59")! == (23, 59))
        #expect(DeviceTime.parseClock("23:60") == nil)
        #expect(DeviceTime.parseClock("ab:cd") == nil)
    }
}

@Suite struct PermissionTests {
    @Test func deniedMapsToPermissionDenied() async {
        let rig = Rig()
        await rig.calendar.set(.reminder, .denied)
        let r = await rig.phone().execute(request("device.reminder.create", ["title": "x"]))
        #expect(r.errorCode == "permission_denied")
        #expect(r.capabilityStatus == .manualUserStep)
        #expect(await rig.calendar.requests == 0)
    }

    @Test func notDeterminedAsksInContext() async {
        let rig = Rig()
        await rig.calendar.set(.reminder, .notDetermined, grant: true)
        let ok = await rig.phone().execute(request("device.reminder.create", ["title": "x"]))
        #expect(ok.ok)
        #expect(await rig.calendar.requests == 1)

        await rig.calendar.set(.reminder, .notDetermined, grant: false)
        let refused = await rig.phone().execute(request("device.reminder.create", ["title": "y"]))
        #expect(refused.errorCode == "permission_denied")
    }

    @Test func restrictedReportsRestricted() async {
        let rig = Rig()
        await rig.contacts.setState(.restricted)
        let r = await rig.phone().execute(request("device.contacts.find", ["query": "a"]))
        #expect(r.errorCode == "permission_denied" && r.capabilityStatus == .restrictedByIos)
    }

    @Test func writeOnlyCalendarCanAddButNotRead() async {
        let rig = Rig()
        await rig.calendar.set(.event, .limited)
        let add = await rig.phone().execute(request("device.calendar.create_event", ["title": "x", "start_at": .string(start)]))
        #expect(add.ok)
        let named = await rig.phone().execute(
            request("device.calendar.create_event", ["title": "x", "start_at": .string(start), "calendar_name": "Work"]))
        #expect(named.errorCode == "permission_denied")
        let read = await rig.phone().execute(request("device.calendar.upcoming"))
        #expect(read.errorCode == "permission_denied")
    }

    @Test func limitedContactsAreEnough() async {
        let rig = Rig()
        await rig.contacts.setState(.limited)
        #expect(await rig.phone().execute(request("device.contacts.find", ["query": "a"])).ok)
    }

    @Test func locationDenied() async {
        let broker = NativeActionBroker(
            platform: .ios, handlers: [LocationHandler(provider: FakeLocation(state: .denied))], confirmer: nil, now: { fixedNow })
        #expect(await broker.execute(request("device.location.current")).errorCode == "permission_denied")
    }

    @Test func alarmsBeforeIOS26AreUnsupported() async {
        let rig = Rig()
        await rig.alarms.setSupported(false)
        let r = await rig.phone().execute(request("ios.alarm.create", ["time": "07:00"]))
        #expect(r.errorCode == "unsupported" && r.capabilityStatus == .unavailable)
    }
}

@Suite struct ConfirmationTests {
    @Test func declinedConfirmationIsUserCancelled() async {
        let rig = Rig()
        let confirmer = FakeConfirmer(false)
        let r = await rig.phone(confirmer: confirmer).execute(
            request("device.whatsapp.compose", ["phone": "+91 98765 43210", "text": "hi"], confirm: true))
        #expect(r.errorCode == "user_cancelled")
        #expect(await rig.opener.opened.isEmpty)
        let asked = await confirmer.asked.first
        #expect(asked?.tool == "device.whatsapp.compose")
        #expect(asked?.summary.contains("+919876543210") == true)
    }

    @Test func acceptedConfirmationRuns() async {
        let rig = Rig()
        let r = await rig.phone(confirmer: FakeConfirmer(true)).execute(
            request("device.whatsapp.compose", ["text": "hi"], confirm: true))
        #expect(r.ok)
        #expect(await rig.opener.opened.count == 1)
    }

    @Test func invalidArgumentsAreNotShownForConfirmation() async {
        let confirmer = FakeConfirmer(true)
        let r = await Rig().phone(confirmer: confirmer).execute(request("device.open_url", ["url": "file:///etc/passwd"], confirm: true))
        #expect(r.errorCode == "invalid_arguments")
        #expect(await confirmer.asked.isEmpty)
    }

    @Test func noConfirmerRefuses() async {
        let rig = Rig()
        let r = await rig.phone().execute(request("device.shortcut.run", ["name": "x"], confirm: true))
        #expect(r.errorCode == "unsupported")
        #expect(await rig.shortcuts.runs.isEmpty)
    }

    @Test func dismissedComposerIsUserCancelled() async {
        let rig = Rig()
        await rig.composer.setOutcome(.cancelled)
        let r = await rig.phone().execute(request("ios.message.compose", ["recipients": ["9876543210"], "body": "hi"]))
        #expect(r.errorCode == "user_cancelled")
    }

    @Test func errorMappingNeverEchoesSystemText() {
        struct Leaky: Error { let detail = "secret" }
        let mapped = NativeActionBroker.map(Leaky())
        #expect(mapped.code == .failed && !mapped.message.contains("secret"))
        #expect(NativeActionBroker.map(ZoroError.userCancelled).code == .userCancelled)
        #expect(NativeActionBroker.map(CancellationError()).code == .failed)
        #expect(NativeActionBroker.map(ZoroError.unavailable(capability: "X", reason: "y")).code == .unsupported)
    }
}
