# Android tests

Scripted tests for the plugin's Android side, run against the demo app on an
emulator and the demo backoffice. They drive the plugin through its real
JavaScript API inside the app's WebView (Chrome DevTools Protocol over adb),
change device state with adb (Home, screen, airplane mode, wifi, battery,
force stop, process kill, reboot) and check the result on both ends: the
plugin's queue database and events, the files the backoffice received (md5),
and the notifications Android shows (`dumpsys notification`).

## Requirements

- Everything from the demo README: emulator running, the app built and seeded
  (`scripts/build.sh`, `scripts/seed-device.sh`), photos on the device.
- Node 22 or later (global `fetch` and `WebSocket`).
- A debug build of the app (WebView debugging is on in debug builds).
- The backoffice running: `node backoffice/server.mjs` (port 8791, or set
  `BACKOFFICE_PORT` for both the server and the tests).

Environment variables: `ANDROID_HOME` or `adb` on `PATH`, `ANDROID_SERIAL` to
pick a device, `BACKOFFICE_PORT`, `OUT_DIR` (results, logcat, screenshots;
default `<system temp dir>/bgsync-android-tests`).

The tests reset the app (queue, WorkManager state, preferences) and the
backoffice before each scenario. Photos on the device are kept.

## Scripts

| Script | What it does |
| --- | --- |
| `scenarios.mjs` | The test matrix. `--list` shows every scenario, `all` runs the quick ones, `all --slow` adds the full 336-photo sync, the 5 minute server timeout and the reboot. Prints PASS/FAIL per case and a markdown table, and writes `results-*.json`. |
| `notification-background.mjs` | Full audit sync with Home and an airplane-mode cut while the app is in the background; samples the server count and the notifications every 5 s and flags a frozen progress notification. `--label`, `--rate` (Mbit/s ingest cap), `--offline-ms`. |
| `eval.mjs` | Runs one expression in the app's WebView with the helpers in scope, for poking at the plugin: `node eval.mjs "plugin('getQueuedRecords')"`. |
| `lib.mjs` | Shared helpers: adb, WebView connection, `plugin(method, ...args)`, event recorder, notification parser, backoffice control. |

```sh
node tests/scenarios.mjs --list
node tests/scenarios.mjs http-errors cancel-resync
node tests/scenarios.mjs all --slow
node tests/notification-background.mjs --label after
```

## Backoffice test support

`backoffice/server.mjs` has a few endpoints used only by the tests:

- `POST /api/faults` with a JSON array of rules (or `FAULTS='[...]'` at start),
  `DELETE /api/faults` to clear. A rule matches requests whose path contains
  `path` (default: every `/api/v1/` and `/upload/` request) and whose record id
  contains `id`, and can answer with `status`, wait `delayMs`, `drop` the
  connection or `hang` (never answer). `every: N` applies it to every Nth
  matching request, `times: N` to the first N. Example:
  `[{"id":"F-03-02","status":500},{"status":503,"every":10},{"delayMs":800}]`
- `GET /api/test/log`: every request that reached a handler, per record id
  (status, bytes, md5), used to count duplicates and check content.
- `POST /api/v1/test/records`: a REST_PAYLOAD sink for any payload with an `id`.
- `POST /api/v1/test/presign`, then `PUT /upload/<key>`: a minimal presigned URL
  flow (handshake returns `uploadUrl`, `method`, `headers`).
- `GET|POST /api/v1/test/download/<id>` (JSON) and
  `GET /api/v1/test/blob/<id>?bytes=N` (deterministic binary) for the download queue.

## What cannot run on an emulator

- Real cellular radio behaviour, carrier NAT timeouts and handovers between
  networks: the emulator's networks are virtual. Wifi and mobile data can be
  switched off and on, which is what the tests do.
- OEM battery savers (aggressive background killers on some vendors' builds):
  the emulator runs stock Android.
- Doze after hours of inactivity: `adb shell dumpsys deviceidle force-idle` can
  approximate it, but it is not part of the matrix.
