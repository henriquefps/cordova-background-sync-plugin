# iOS simulator tests

Automated tests of the plugin's iOS side, run against the field audit demo on
the iOS simulator. They drive a test build of the app remotely, inject faults
in the backoffice and check the results on the server, in the plugin's queue
database and in the app's events.

## How it works

- **Test build.** `VITE_TEST_CONTROL=1 scripts/ios-build.sh` bundles
  `app/src/testControl.js`. The app then long-polls the backoffice for
  commands (plugin calls, app actions such as tapping Sync, or a JS snippet),
  runs them and posts the results back. It also forwards every listener event
  (`onStarted`, `onProgress`, `onFailed`, `onCompleted` and the `_download`
  ones) with the device time. A normal build does not include any of this.
- **Test API.** `TEST_API=1 node backoffice/server.mjs` adds the control
  channel, fault injection (`POST /api/fault`: HTTP status, dropped connection
  or no answer, per record id) and endpoints for features the photo audit does
  not use: any REST upload, presigned-URL handshake and PUT, REST and binary
  downloads. See the header of `backoffice/test-api.mjs`.
- **Network loss.** The simulator has no airplane mode, and the control
  channel needs the backoffice. `network-loss` points the plugin at a TCP proxy
  in front of the backoffice and closes the proxy, which the plugin sees as a
  real connection loss.
- **Lifecycle.** `xcrun simctl` terminates and relaunches the app. Bringing
  Settings to the front stands in for the Home button, which `simctl` cannot
  press.
- **Memory.** `footprint` samples the app process (simulator apps are Mac
  processes).

## Run

```sh
cd examples/field-audit-demo
export BACKOFFICE_PORT=8791            # any free port; the app is built for it
TEST_API=1 PORT=$BACKOFFICE_PORT node backoffice/server.mjs &
VITE_TEST_CONTROL=1 scripts/ios-build.sh
scripts/ios-seed.sh                    # boots the simulator, installs, copies the photos
xcrun simctl launch booted com.hfps.fieldaudit   # allow notifications when asked
node tests/ios/run.mjs                 # every case, about 15 minutes
# With a second backoffice running (for example the Android tests on 8791),
# give this one its own DATA_DIR and pass the same DATA_DIR to run.mjs.
node tests/ios/run.mjs cancel downloads   # or some of them
```

`SIM_DEVICE` (default `iPhone 17 Pro`) or `SIM_UDID` selects the simulator.
Each case writes `tests/ios/results/<case>.json`, and the run writes
`tests/ios/results/summary.md` (expected, observed, result per case). Cases
reset the plugin queue and the backoffice first, so they can run in any
order; they leave the queue in whatever state they end in.

## Cases

| Case | What it checks |
| --- | --- |
| `full-sync` | 336 photos, md5 of every file, queue rows, event counts and order, memory |
| `background` | Home mid-run: uploads during the background window, the stop, resume on return, no second run when `sync()` is called on return |
| `terminate` | App killed mid-run and relaunched: no loss, the next sync continues |
| `network-loss` | Server unreachable mid-run, then back: failure reported, automatic resume |
| `http-errors` | 500 and 413 on five photos: the rest of the queue goes on, retry on the next sync |
| `cancel` | `cancelSync` mid-run, then `sync` |
| `remove-during-run` | `removeRecords` (with non-string ids) and `clearQueue` while a run is going |
| `remove-after` | `removeRecords`, `removeDownloads`, `clearQueue`, `clearDownloadQueue`, numeric ids |
| `bad-input` | Numbers and nulls where the API expects text |
| `dup-ids` | The same id enqueued twice, and again after it completed |
| `enqueue-during-run` | `enqueueRecord` and three `enqueueSync` calls during a run |
| `auto-delete` | `autoDeleteCompleted: true` for uploads and paged downloads |
| `downloads` | REST and BINARY_FILE downloads, a 404, pagination, listener names |
| `presigned` | PRESIGNED_URL handshake and PUT, md5, headers, a failed handshake, a missing file |
| `raw-query` | `executeRawQuery` with SELECT, PRAGMA, WITH, writes, bad SQL, a constraint violation |
| `encrypt` | `encryptDatabase: true` on an existing plain database, across a relaunch |
| `large-file` | 20 MB and 70 MB REST_PAYLOAD uploads: md5 and memory |
| `inspector-layout` | The inspector table at phone width (renders `www/inspector/inspector.html` in the app's WKWebView) |

## Checked by hand

These need taps the simulator does not take from scripts.

- **Notification permission.** On a fresh install (`xcrun simctl uninstall`,
  then `scripts/ios-seed.sh`), the app calls `requestNotificationsPermission`
  at start and iOS shows its prompt. After **Don't Allow** the call resolves
  `false` and a sync still completes. Notifications can only be reset by
  reinstalling the app.
- **Notifications during a sync.** With permission granted, start a sync,
  press Home and open Notification Center: the progress notification is
  there (passive, without a banner). With `enableNotifications: false`
  nothing is posted.
- **Database Inspector.** `openDatabaseInspector`, then **Export All (JSON)**
  opens the share sheet with `bg_sync_export_<time>.json`, and **Close**
  dismisses it. Opening and closing it a few times must not leave
  `com.apple.WebKit.WebContent` processes behind
  (`pgrep -fl WebContent | grep -c CoreSimulator`).
