"""The device contract table as data (docs/architecture/device-contract.md, "Tools").

One `DeviceToolRow` per row: name, risk and data class exactly as in the table, platforms from
the name prefix, plus what the backend adds (agents, MCP group, permission, honest per-platform
status for the capability registry).
"""

from __future__ import annotations

from dataclasses import dataclass, field

from pydantic import BaseModel

from app.core.types import AgentId, CapabilityStatus, DataClass, DevicePlatform, RiskLevel
from app.devices import tool_io as io

A = AgentId
S = CapabilityStatus
IOS = DevicePlatform.IOS
MAC = DevicePlatform.MACOS

# Permission keys declared by this package: (key, title, default).
PERM_CALENDAR = "devices.calendar"
PERM_CONTACTS = "devices.contacts"
PERM_NOTIFY = "devices.notifications"
PERM_LOCATION = "devices.location"
PERM_CONTROL = "devices.control"
PERM_PHOTOS = "devices.photos"
PERM_HEALTH = "health.read"  # the one health grant, shared with the fitness package
PERM_COMPOSE = "devices.compose"
PERM_HOME = "devices.home"
PERM_MAC_AUTOMATION = "devices.mac_automation"
PERM_MAC_FILES = "devices.mac_files"

PERMISSIONS: tuple[tuple[str, str, bool], ...] = (
    (PERM_CALENDAR, "Read and add calendar events and reminders on your devices", True),
    (PERM_CONTACTS, "Look up and save contacts on your devices", True),
    (PERM_NOTIFY, "Schedule notifications on your devices", True),
    (PERM_LOCATION, "Read your device's current location", False),
    (PERM_CONTROL, "Alarms, timers, shortcuts, music and opening links on your devices", True),
    (PERM_PHOTOS, "Search the on-device photo index (identifiers only)", True),
    # Same title and default as the fitness package's declaration of this key (a mismatch fails at startup).
    (PERM_HEALTH, "Let ZORO read your synced fitness and health summaries", True),
    (PERM_COMPOSE, "Prepare WhatsApp and Messages drafts that you send yourself", True),
    (PERM_HOME, "Run Home scenes and allowlisted Home Assistant actions", True),
    (PERM_MAC_AUTOMATION, "Run allowlisted AppleScripts on your Mac", False),
    (PERM_MAC_FILES, "Search and open files in folders you approved on your Mac", False),
)


@dataclass(frozen=True)
class DeviceToolRow:
    name: str
    description: str
    input_model: type[BaseModel]
    output_model: type[BaseModel]
    risk: RiskLevel
    data_class: DataClass
    agents: frozenset[AgentId]
    mcp_group: str
    permission: str
    native_api: str
    status: dict[DevicePlatform, CapabilityStatus]  # honest status per platform the tool targets
    platform_notes: dict[DevicePlatform, str] = field(default_factory=dict)
    timeout_s: float = 20
    untrusted_output: bool = False

    @property
    def platforms(self) -> frozenset[DevicePlatform]:
        return platforms_for(self.name)


def platforms_for(tool_name: str) -> frozenset[DevicePlatform]:
    """`device.*` runs on iPhone and Mac, `ios.*` only on iPhone, `mac.*` only on Mac."""
    prefix = tool_name.split(".", 1)[0]
    if prefix == "ios":
        return frozenset({IOS})
    if prefix == "mac":
        return frozenset({MAC})
    if prefix == "device":
        return frozenset({IOS, MAC})
    raise ValueError(f"not a device tool name: {tool_name}")


def _both(status: CapabilityStatus = S.WORKING_NATIVE) -> dict[DevicePlatform, CapabilityStatus]:
    return {IOS: status, MAC: status}


_DC = A.DEVICE_CONTROL
_PA = A.PERSONAL_ASSISTANT

ROWS: tuple[DeviceToolRow, ...] = (
    DeviceToolRow(
        "device.reminder.create", "Create a reminder in the owner's Reminders.",
        io.ReminderCreateIn, io.CreatedOut, RiskLevel.MEDIUM, DataClass.PERSONAL,
        frozenset({_DC, _PA}), "calendar-mcp", PERM_CALENDAR, "EventKit", _both(),
    ),
    DeviceToolRow(
        "device.calendar.create_event", "Add an event to the owner's calendar.",
        io.EventCreateIn, io.CreatedOut, RiskLevel.MEDIUM, DataClass.PERSONAL,
        frozenset({_DC, _PA}), "calendar-mcp", PERM_CALENDAR, "EventKit", _both(),
    ),
    DeviceToolRow(
        "device.calendar.upcoming", "List the owner's upcoming calendar events.",
        io.UpcomingIn, io.UpcomingOut, RiskLevel.LOW, DataClass.PERSONAL,
        frozenset({_DC, _PA}), "calendar-mcp", PERM_CALENDAR, "EventKit", _both(),
        untrusted_output=True,  # invitations carry text written by other people
    ),
    DeviceToolRow(
        "device.contacts.find", "Find contacts by name, phone or email.",
        io.ContactsFindIn, io.ContactsFindOut, RiskLevel.LOW, DataClass.PERSONAL,
        frozenset({_DC, _PA, A.COMMUNICATION}), "ios-device-mcp", PERM_CONTACTS, "Contacts", _both(),
    ),
    DeviceToolRow(
        "device.contacts.save", "Save a new contact.",
        io.ContactSaveIn, io.ContactSaveOut, RiskLevel.MEDIUM, DataClass.PERSONAL,
        frozenset({_DC, _PA, A.COMMUNICATION}), "ios-device-mcp", PERM_CONTACTS, "Contacts", _both(),
    ),
    DeviceToolRow(
        "device.notification.schedule", "Schedule a local notification on a device.",
        io.NotificationIn, io.CreatedOut, RiskLevel.MEDIUM, DataClass.PERSONAL,
        frozenset({_DC, _PA, A.AUTOMATION}), "notification-mcp", PERM_NOTIFY, "UserNotifications", _both(),
    ),
    DeviceToolRow(
        "device.location.current", "Read the device's current location.",
        io.LocationIn, io.LocationOut, RiskLevel.LOW, DataClass.SENSITIVE,
        frozenset({_DC, _PA}), "location-mcp", PERM_LOCATION, "Core Location", _both(),
    ),
    DeviceToolRow(
        "device.open_url", "Open an https link or an allowlisted app link on a device.",
        io.OpenUrlIn, io.OpenedOut, RiskLevel.LOW, DataClass.PUBLIC,
        frozenset({_DC, _PA, A.SHOPPING}), "ios-device-mcp", PERM_CONTROL, "open URL / universal link",
        _both(),
    ),
    DeviceToolRow(
        "device.shortcut.run", "Run one of the owner's Shortcuts by name.",
        io.ShortcutRunIn, io.StartedOut, RiskLevel.MEDIUM, DataClass.PERSONAL,
        frozenset({_DC, A.AUTOMATION}), "ios-device-mcp", PERM_CONTROL, "Shortcuts",
        {IOS: S.MANUAL_USER_STEP, MAC: S.WORKING_NATIVE},
        {IOS: "Hands off to the Shortcuts app (shortcuts://).", MAC: "Runs `shortcuts run`."},
    ),
    DeviceToolRow(
        "device.music.control", "Play, pause, skip or search-and-play music.",
        io.MusicControlIn, io.MusicControlOut, RiskLevel.LOW, DataClass.PERSONAL,
        frozenset({_DC, A.MUSIC}), "music-mcp", PERM_CONTROL, "MusicKit; Spotify app by URL / AppleScript",
        _both(),
        {IOS: "Spotify is opened by URL; playback runs in the Spotify app.", MAC: "Spotify via AppleScript."},
    ),
    DeviceToolRow(
        "device.photos.search", "Search the on-device photo index (identifiers only, never images).",
        io.PhotosSearchIn, io.PhotosSearchOut, RiskLevel.LOW, DataClass.PERSONAL,
        frozenset({_DC, A.VISION}), "ios-photos-mcp", PERM_PHOTOS, "PhotoKit + Vision index", _both(),
        timeout_s=30,
        untrusted_output=True,  # matched[] may hold text recognised in screenshots
    ),
    DeviceToolRow(
        "device.health.query", "Read Apple Health aggregates for a metric and date range.",
        io.HealthQueryIn, io.HealthQueryOut, RiskLevel.LOW, DataClass.HEALTH,
        frozenset({_DC, A.FITNESS}), "fitness-mcp", PERM_HEALTH, "HealthKit",
        {IOS: S.WORKING_NATIVE, MAC: S.UNAVAILABLE},
        {MAC: "HealthKit data lives on the iPhone; the Mac answers unsupported."},
        timeout_s=30,
    ),
    DeviceToolRow(
        "device.whatsapp.compose", "Open WhatsApp with a prepared message; the owner taps send.",
        io.WhatsAppComposeIn, io.OpenedOut, RiskLevel.HIGH, DataClass.PERSONAL,
        frozenset({_DC, A.COMMUNICATION}), "communication-mcp", PERM_COMPOSE, "https://wa.me/",
        _both(S.MANUAL_USER_STEP),
    ),
    DeviceToolRow(
        "ios.alarm.create", "Set an alarm on the iPhone.",
        io.AlarmCreateIn, io.AlarmCreateOut, RiskLevel.MEDIUM, DataClass.PERSONAL,
        frozenset({_DC, _PA}), "ios-device-mcp", PERM_CONTROL, "AlarmKit (iOS 26+)",
        {IOS: S.WORKING_NATIVE}, {IOS: "Needs iOS 26 or later (AlarmKit)."},
    ),
    DeviceToolRow(
        "ios.timer.start", "Start a countdown timer on the iPhone.",
        io.TimerStartIn, io.TimerStartOut, RiskLevel.MEDIUM, DataClass.PERSONAL,
        frozenset({_DC, _PA}), "ios-device-mcp", PERM_CONTROL, "AlarmKit countdown (iOS 26+)",
        {IOS: S.WORKING_NATIVE}, {IOS: "Needs iOS 26 or later (AlarmKit)."},
    ),
    DeviceToolRow(
        "ios.message.compose", "Open the Messages composer with a prepared text; the owner taps send.",
        io.MessageComposeIn, io.MessageComposeOut, RiskLevel.HIGH, DataClass.PERSONAL,
        frozenset({_DC, A.COMMUNICATION}), "communication-mcp", PERM_COMPOSE, "Message composer",
        {IOS: S.MANUAL_USER_STEP},
    ),
    DeviceToolRow(
        "ios.home.run_scene", "Run a HomeKit scene.",
        io.HomeSceneIn, io.RanOut, RiskLevel.MEDIUM, DataClass.PERSONAL,
        frozenset({_DC, A.AUTOMATION}), "ios-device-mcp", PERM_HOME, "HomeKit", {IOS: S.WORKING_NATIVE},
    ),
    DeviceToolRow(
        "mac.applescript.run", "Run an allowlisted AppleScript on the Mac (never model-written script).",
        io.AppleScriptRunIn, io.AppleScriptRunOut, RiskLevel.MEDIUM, DataClass.PERSONAL,
        frozenset({_DC, A.AUTOMATION}), "mac-device-mcp", PERM_MAC_AUTOMATION, "allowlisted AppleScript",
        {MAC: S.WORKING_NATIVE}, {MAC: "Only scripts the owner allowlisted in the Mac app."},
    ),
    DeviceToolRow(
        "mac.file.search", "Search files with Spotlight in folders the owner approved.",
        io.FileSearchIn, io.FileSearchOut, RiskLevel.LOW, DataClass.PERSONAL,
        frozenset({_DC, A.DOCUMENT}), "mac-device-mcp", PERM_MAC_FILES, "Spotlight",
        {MAC: S.WORKING_NATIVE}, {MAC: "Limited to folders the owner approved."},
        untrusted_output=True,  # file names are arbitrary text
    ),
    DeviceToolRow(
        "mac.file.open", "Open a file found earlier on the Mac.",
        io.FileOpenIn, io.OpenedOut, RiskLevel.LOW, DataClass.PERSONAL,
        frozenset({_DC, A.DOCUMENT}), "mac-device-mcp", PERM_MAC_FILES, "NSWorkspace",
        {MAC: S.WORKING_NATIVE},
    ),
)  # fmt: skip

ROWS_BY_NAME: dict[str, DeviceToolRow] = {row.name: row for row in ROWS}

# "Not available" in the device contract: (id suffix, title).
RESTRICTED_BY_IOS: tuple[tuple[str, str], ...] = (
    ("wake_word", "Replace Siri's wake word"),
    ("background_listening", "Listen in the background without an active audio session"),
    ("read_other_apps", "Read SMS, WhatsApp or other apps' data"),
    ("silent_send", "Send messages silently"),
    ("drive_other_apps", "Drive other apps' interfaces"),
    ("apple_notes_direct", "Create Apple Notes directly"),
)
