# Calendar

View your Google Calendar(s) on KOReader — as the sleep screen (screensaver) and
in an interactive viewer opened from a gesture or the Tools menu. Read-only.

## How it works

Google Calendar can't practically be reached with OAuth on an e-ink device, but
every calendar exposes a private **"Secret address in iCal format"** — an
unguessable `https://.../basic.ics` URL that needs no login. The plugin downloads
those ICS feeds over HTTPS, caches them on disk (so it still shows the last data
when offline), parses events (including common recurring events), and renders
them in **day / week / month / agenda** views.

## Setup

1. **Get your calendar URL(s).** In Google Calendar (web): Settings → click your
   calendar under *Settings for my calendars* → *Integrate calendar* → copy
   **Secret address in iCal format** (ends with `/basic.ics`). Each calendar has
   its own URL.
2. **Create the config file.** Copy `calendar_configuration.sample.lua` to
   `calendar_configuration.lua` (in this folder) and paste your URL(s) into the
   `calendars` list. Editing on a computer is far easier than typing on-device.
   - Or, on-device: Tools → Calendar → Calendars → **Create configuration file
     from sample**, then edit the created file.
3. **Load it.** Restart KOReader, or Tools → Calendar → Calendars → **Reload
   configuration**.

Your `calendar_configuration.lua` holds private URLs and is git-ignored — never
share it.

## Using it

- **Tools → Calendar → Open viewer** — interactive; buttons switch Day/Week/
  Month/Agenda (active mode shown in brackets), `<` / `Today` / `>` navigate,
  `Sync` force-refetches all calendars without leaving the viewer (offering to
  enable Wi-Fi if it is off), `X` closes. Swiping left/right also pages
  through periods. The viewer
  remembers the last mode you used, opens instantly from the cache, and — if
  the cache is stale and Wi-Fi is already connected — refreshes right after
  opening (with a "Refreshing calendars…" message). Today is highlighted in
  every view.
- **Tools → Calendar → Calendars** — tap a calendar to show/hide it without
  editing the config file (the choice persists across reloads).
- **Gesture** — assign *Open calendar* / *Refresh calendar* in KOReader's
  Gestures settings.
- **Sleep screen** — Sleep screen / Wallpaper settings → **Show calendar on
  sleep screen**, then pick the view mode right below it.
- **Refresh** — on sleep, calendars older than the refresh interval are
  refetched when Wi-Fi is already connected; or Tools → Calendar → **Refresh
  now**. Optionally (off by default), **Turn on Wi-Fi on sleep if outdated**
  briefly enables Wi-Fi at sleep when the cache is older than a configurable
  threshold, refreshes, then turns it off again — note this can delay entering
  sleep by up to ~30 s and uses some battery.

## Preferences

Set from the menus (not the config file): sleep-screen view mode, week start
(Mon/Sun), refresh interval (hours), and the opt-in sleep-time Wi-Fi refresh
with its staleness threshold (hours).

## Languages

The UI follows KOReader's language setting. Because out-of-tree plugins are
not covered by KOReader's central translation files, this plugin ships its own
dictionaries in `calendar_l10n/` — currently **Turkish, German, French,
Spanish, Italian and Portuguese**. Anything missing falls back to KOReader's
core translations (common words) and then to English. Weekday/month names come
from KOReader's own `datetime` tables, so dates are localized in **every**
KOReader language automatically. To add a language, copy
`calendar_l10n/tr.lua` to `calendar_l10n/<code>.lua` and translate the values.

## Limitations

- Timezones: each event's `TZID` is converted to the device's local time.
  Recurrences retain the source timezone's wall-clock time across DST changes.
  Embedded `VTIMEZONE` definitions support STANDARD/DAYLIGHT, RDATE and yearly
  BYMONTH/BYDAY/BYMONTHDAY transition rules (as exported by Google Calendar).
  When definitions are absent, the device's Unix zoneinfo database is used
  if available. An unresolved TZID raises an explicit error rather than
  silently displaying the wrong time. Exotic VTIMEZONE recurrence rules are
  not supported. Date-only events remain local calendar dates; floating times
  without TZID or Z use the device's local timezone.
- Recurrence: supports `FREQ` DAILY/WEEKLY/MONTHLY/YEARLY with
  INTERVAL/COUNT/UNTIL/BYDAY, EXDATE, and single-occurrence overrides via
  `RECURRENCE-ID` (a rescheduled instance shows only at its new time).
  `DURATION` is used when `DTEND` is absent. Exotic RFC-5545 rules are not
  expanded.
- In the interactive viewer, day/week/month cells are compact and may not fit
  an event's full text; tap a day, hour row, or event to see its full details
  (time, location, description). This tap-to-detail popup is not available on
  the sleep-screen (screensaver) view, which is a static snapshot.
