# Device contract

Normative. Shared by the backend `devices`, `vision`, `fitness` packages and the Swift packages
`ZoroDevice` (NativeActionBroker, HealthIntegration, MusicIntegration) and `ZoroPhotos` (PhotoIntelligence).
A device tool is declared on the backend with `executor="device"`; the app executes it natively and answers
with `DeviceActionResult` (`backend/app/schemas/turns.py`). Arguments and results are JSON objects with
snake_case keys. Times are ISO-8601 with offset; local wall-clock times are `"HH:MM"` (24-hour).

Prefixes: `device.*` runs on iPhone and Mac, `ios.*` only on iPhone, `mac.*` only on Mac.
A device that cannot run a tool answers `ok=false`, `error_code="unsupported"` and the matching
`capability_status`. Missing system permission → `error_code="permission_denied"`. The owner dismissing a
system sheet → `error_code="user_cancelled"`.

## Tools

| Tool | Arguments | Result | Risk | Data class | Native API |
|---|---|---|---|---|---|
| `device.reminder.create` | `title`, `due_at?`, `notes?`, `list_name?` | `id` | medium | personal | EventKit |
| `device.calendar.create_event` | `title`, `start_at`, `end_at?`, `location?`, `notes?`, `calendar_name?` | `id` | medium | personal | EventKit |
| `device.calendar.upcoming` | `from?`, `to?`, `limit?` (default 5) | `events[]`: `id`, `title`, `start_at`, `end_at`, `location?`, `calendar` | low | personal | EventKit |
| `device.contacts.find` | `query` | `matches[]`: `contact_ref`, `name`, `phones[]`, `emails[]` | low | personal | Contacts |
| `device.contacts.save` | `given_name`, `family_name?`, `phone?`, `email?` | `contact_ref` | medium | personal | Contacts |
| `device.notification.schedule` | `title`, `body`, `at?` | `id` | medium | personal | UserNotifications |
| `device.location.current` | — | `place_ref`, `locality?`, `latitude`, `longitude`, `accuracy_m` | low | sensitive | Core Location |
| `device.open_url` | `url` (https, or an allowlisted app scheme) | `opened` | low | public | open URL / universal link |
| `device.shortcut.run` | `name`, `input?` | `started` | medium | personal | Shortcuts (iPhone: `shortcuts://` handoff; Mac: `shortcuts run`) |
| `device.music.control` | `provider` (`apple_music` \| `spotify_app`), `action` (`play` \| `pause` \| `next` \| `previous` \| `search_play`), `query?`, `uri?` | `now_playing?`: `title`, `artist`, `provider` | low | personal | MusicKit; Spotify app by URL / AppleScript on Mac |
| `device.photos.search` | `query`: PhotoQuery | `hits[]`: `asset_id`, `captured_at`, `score`, `labels[]`, `matched[]`; `indexed_count`, `limited_library` | low | personal | PhotoKit + Vision index (identifiers only, never image bytes) |
| `device.health.query` | `metric`, `from`, `to`, `bucket` (`day` \| `week`) | `points[]`: `start`, `value`, `unit`; `sources[]`, `latest_sample_at` | low | health | HealthKit (iPhone; Mac answers `unsupported`) |
| `device.whatsapp.compose` | `phone?` (international digits), `text` | `opened` | high | personal | `https://wa.me/…` — the owner taps send in WhatsApp |
| `ios.alarm.create` | `time` (`HH:MM`), `label?`, `repeat_days?` (`mon`…`sun`) | `alarm_id` | medium | personal | AlarmKit (iOS 26+) |
| `ios.timer.start` | `seconds`, `label?` | `timer_id` | medium | personal | AlarmKit countdown (iOS 26+) |
| `ios.message.compose` | `recipients[]` (phone numbers), `body` | `presented`, `sent?` | high | personal | Message composer — the owner taps send |
| `ios.home.run_scene` | `scene_name` | `ran` | medium | personal | HomeKit |
| `mac.applescript.run` | `script_id` (allowlisted name), `params?` | `output?` | medium | personal | allowlisted AppleScript only, never model-written script text |
| `mac.file.search` | `query`, `folder_ref?` | `files[]`: `path_ref`, `name`, `modified_at` | low | personal | Spotlight, limited to folders the owner approved |
| `mac.file.open` | `path_ref` | `opened` | low | personal | NSWorkspace |

Clarifications:

- Error codes: `permission_denied`, `unsupported`, `user_cancelled`, `invalid_arguments`, `expired`, `failed`.
- `device.health.query` metrics and units: `steps` (count), `walking_running_distance` (m),
  `cycling_distance` (m), `active_energy` (kcal), `exercise_minutes` (min), `heart_rate` (bpm),
  `resting_heart_rate` (bpm), `sleep` (min), `body_mass` (kg).
- `device.music.control`: `provider` may be omitted; the device then picks the provider that is authorised
  and active, and names it in the result.
- `place_ref` is a `geo:` URI (RFC 5870) with uncertainty, for example `geo:12.97,77.59;u=65`.
- `path_ref` is `<folder_ref>:<relative path>` inside a folder the owner approved; absolute paths are refused.
- A denied system permission is reported in the capability registry as `manual_user_step` (the owner can
  grant it in Settings) and a blocked or absent one as `unavailable`, with the reason in the note.

Not available to any third-party app, recorded in the capability registry as `restricted_by_ios`: replacing
Siri's wake word, listening in the background without an active audio session, reading SMS / WhatsApp /
other apps' data, silently sending messages, driving other apps' interfaces, creating Apple Notes directly
(done through a Shortcut the owner makes).

## PhotoQuery

```json
{
  "text": "photo from yesterday with my blue cap",
  "date_from": "2026-11-11", "date_to": "2026-11-11",
  "colors": ["blue"],
  "labels": ["cap", "hat"],
  "contains_text": null,
  "media": "any",
  "limit": 30
}
```

`media` is `photo`, `screenshot` or `any`. The backend `vision` package parses the owner's words into this
shape (dates resolved in the owner's time zone; colour and object words in English, Hindi and Hinglish);
the device may also parse on its own when offline. Search combines date filter, extracted text, labels,
dominant colours and embedding similarity. Images never leave the device.

## Fitness sync

The iPhone reads HealthKit and posts aggregates to `POST /v1/fitness/sync`; raw samples stay on the device.

```json
{
  "generated_at": "2026-11-13T06:30:00+05:30",
  "days": [{
    "date": "2026-11-12", "steps": 8421, "walking_running_distance_m": 6120.5,
    "cycling_distance_m": 0, "active_energy_kcal": 412.0, "exercise_minutes": 38,
    "resting_heart_rate_bpm": 58, "avg_heart_rate_bpm": 74, "sleep_minutes": 402,
    "body_mass_kg": null, "sources": ["Apple Watch", "iPhone"]
  }],
  "workouts": [{
    "id": "hk-uuid", "type": "running", "start_at": "2026-11-12T06:10:00+05:30",
    "end_at": "2026-11-12T06:42:10+05:30", "duration_s": 1930, "distance_m": 5020.0,
    "active_energy_kcal": 331.0, "avg_heart_rate_bpm": 152, "avg_pace_s_per_km": 384.5,
    "source": "Apple Watch"
  }]
}
```

Workout `type`: `running`, `walking`, `cycling`, `strength`, `yoga`, `swimming`, `other`. Every value may be
null when the owner has not granted that data type; nothing is estimated. (The numbers above only
illustrate the shape.)
