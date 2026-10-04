# Android test results (Background Sync 1.0.5, Android side)

Device: emulator, AVD `Medium_Phone_API_36.1` (Android 16, API 36), WorkManager
2.9.0, demo app debug build. Backoffice on the host (`node backoffice/server.mjs`),
reached at `http://10.0.2.2:8791`. Scripts: `tests/scenarios.mjs` and
`tests/notification-background.mjs` (see [README.md](README.md)).

Baseline: the same scenarios run against a build of 1.0.4 (the commit before
these changes), to confirm each bug before fixing it.

## The frozen progress notification

Scenario (`notification-background.mjs`): full audit sync (336 photos) with a
32 Mbit/s ingest cap, Home once 15 photos are on the server, airplane mode on
for 10 s and off again while the app stays in the background. Samples every
5 s: photos on the server, and the app's notifications from
`dumpsys notification --noredact`.

Before (1.0.4): the airplane-mode cut ends the run with `Result.retry()`, the
retry starts in the background, and Android refuses the foreground service:

```
E/ActivityManager: Background started FGS: Disallowed [callingPackage: com.hfps.fieldaudit; ... uidState: TRNB ...]
W/ActivityManager: startForegroundService() not allowed due to mAllowStartForeground false: service com.hfps.fieldaudit/androidx.work.impl.foreground.SystemForegroundService
W/BackgroundSyncPlugin: Failed to run as Foreground Service: ... Falling back to standard background execution.
```

Every later progress update went through `setForeground` and failed (198
`Failed to update Foreground Service progress notification` lines in that run).
The notification stopped at `Photo 100 of 298 (33%)` for 2 minutes while the
server went from 138 to 332 photos:

```
  75s server=127  Photo 90 of 298 (30%)
  80s server=138  Photo 100 of 298 (33%)
  86s server=147  Photo 100 of 298 (33%)
 ...
 197s server=323  Photo 100 of 298 (33%)
 202s server=332  Photo 100 of 298 (33%)
 207s server=336  All photos are on the server.
```

After: the same scenario. The run started from the background does not try to
start the foreground service (Android 12+ only allows it while the app is
visible), posts its progress with `NotificationManager.notify`, and the
notification follows the uploads to the end. During the cut it says the sync
is paused, which is what happened:

```
(* = ongoing, F = foreground service notification)
   9s server= 18  [home]          1002*F Photo 16 of 336 (4%)
  19s server= 41  [airplane on]   1002*F Photo 40 of 336 (11%)
  30s server= 42  [airplane off]  1003   Synchronization Paused | 41 of 336 done. The sync resumes automatically when Android allows it.
  35s server= 47                  1002*  Photo 7 of 295 (2%)
  80s server=153                  1002*  Photo 111 of 295 (37%)
 121s server=248                  1002*  Photo 206 of 295 (69%)
 156s server=330                  1002*  Photo 289 of 295 (97%)
 161s server=336                  1003   Audit synced | All photos are on the server.   (nothing ongoing left)
```

What was evaluated and not kept: an expedited request
(`setExpedited(RUN_AS_NON_EXPEDITED_WORK_REQUEST)`). The work ran as an
expedited job (`runEJ=1` in `dumpsys jobscheduler`) and Android 16 still
answered `Background started FGS: Disallowed`. It also cannot be combined with
`syncOnlyWhenCharging` or a start delay, and retries with backoff are never
expedited, so it would not help the retry case at all.

## Bugs found, fixed and retested

All fixes are in commit `5e80fa8` (src/android only).

| # | Bug (1.0.4) | Evidence before | Root cause | Fix | Retest |
| --- | --- | --- | --- | --- | --- |
| 1 | Progress notification frozen after a run starts in the background (Android 12+) | Above: stuck at 100 of 298 for 2 min | Progress updates went through `setForeground`, which fails when the foreground service cannot start | Progress posted with `NotificationManager.notify` on the progress id; `setForeground` only to promote | `notification-background.mjs` pass |
| 2 | A background run is not stopped or rescheduled by the system; it hangs in a frozen process with an ongoing notification | `system-stop-background`: after the charging constraint was lost the worker never logged a stop, uploads froze, notification stayed ongoing; WorkManager later logged `Unable to stop foreground service` | A failed `setForeground` leaves WorkManager 2.9 treating the work as foreground, so it ignores system stops | On Android 12+ `setForeground` is only called while the app is visible; retried (every 5 s at most) when it becomes visible | `system-stop-background` and `repromote-visible` pass |
| 3 | No final notification after a run that ran as a foreground service | `http-errors` on 1.0.4: notifications `none` at the end | The final notification used the foreground service's id; WorkManager removes that notification when the service stops | Final notifications on their own id (1003); progress id cancelled at the end | `http-errors` pass |
| 4 | "All offline records successfully uploaded" after a run where the server rejected items, plus one alert with sound per rejected item | code review, `http-errors` | Success notification did not look at failures; per-item `updateNotificationFailure` | One final notification: success, finished with errors (`partialTitle`/`partialBody`), suspended, or paused | `http-errors` pass |
| 5 | Records removed during a run (`removeRecords`, `clearQueue`) are still sent, with an empty payload | `clear-remove-during-run` on 1.0.4: removed records sent as `{"payload":""}` (server request without an id) | The run kept its in-memory list; a missing row produced an empty payload | A record whose row is gone is skipped | pass |
| 6 | `enqueueSync` during a run cancels it (and the JS layer calls `enqueueSync` on every `online` event); the cancelled run and its replacement could overlap | Code review only: `cancelUniqueWork` + `REPLACE` on every call. `cancel-resync` and `enqueue-during-run` passed on 1.0.4 too (no duplicates with these timings), so this is a defensive fix | A cancelled CoroutineWorker keeps its thread until the blocking upload returns, so a replacement could load the same pending record | Running worker kept, one follow-up run chained (`APPEND_OR_REPLACE`); records enqueued mid-run sent by the same run; one run at a time per process (mutex) | `enqueue-during-run`, `cancel-resync` pass, no duplicates |
| 7 | 60 MB `REST_PAYLOAD` upload crashes with `OutOfMemoryError`; the record stays pending and every retry crashes again | `large-file` on 1.0.4: 4 OOM lines, nothing on the server after 10 min | File bytes, base64 string and serialized JSON body all in memory (about 4x the file) | Body streamed: base64 encoded while writing, fixed-length streaming mode | 60 MB in 6 s, md5 match, no OOM |
| 8 | A `filePath` that does not exist: payload sent without the file and the record marked `completed` | `missing-file` on 1.0.4 | `if (file.exists())` silently skipped the file | Record marked `failed` with `Local file not found at path: ...` | pass |
| 9 | `file://` paths with percent-encoded characters (`%20`) not found, so sent without the file (bug 8) | `file-url-encoding` on 1.0.4 | `replace("file://", "")` without decoding | Paths parsed as URIs and decoded (REST, presigned, file download) | pass, md5 match |
| 10 | `executeRawQuery` rejects `WITH ... SELECT` | `raw-query`: "Queries can be performed using SQLiteDatabase query or rawQuery methods only" | Only `SELECT`/`PRAGMA` went to `rawQuery` | `WITH`, `EXPLAIN`, `VALUES` also go to `rawQuery` | pass |
| 11 | Empty queue: every `enqueueSync` (every `online` event) started the foreground service and posted "Synchronization Complete" | code review | Success notification posted for zero records | Nothing posted, no foreground service | `empty-queue` pass |

## Test matrix (final build)

Run with `node tests/scenarios.mjs all --slow` on the final build, plus
`notification-background.mjs` above. Every scenario resets the app and the
backoffice first.

| Case | What was done | Expected | Observed | Result |
| --- | --- | --- | --- | --- |
| Full sync | 336 photos queued, `enqueueSync` | all on the server, md5 identical, 336 rows completed | 336 photos, 418,184,992 bytes, 0 md5 mismatches, 336 completed, success notification only; 40 s without an ingest cap | pass |
| Home, airplane in background | `notification-background.mjs` | notification advances, final success, nothing ongoing | see above | pass |
| Screen off / locked | 40 records, screen off after 5 | uploads continue, notification follows | 21 sent after 8 s screen off, then 40; progress ongoing mid-run, success at the end | pass |
| Swiped from recents | swipe the task away mid-run | uploads continue, each record once | 40 delivered, 0 duplicates | pass |
| Force stop, reopen | `am force-stop` mid-run, wait 15 s, open the app | nothing runs while stopped (Android rule), resumes on open without a new `enqueueSync` | 5 at stop, 6 after 15 s (in-flight one), no notification left, all 40 after reopen, 1 re-send (the in-flight record) | pass |
| Process killed | `kill -9` of the app process mid-run, app not reopened | WorkManager restarts the work in a new process | resumed in a new process within seconds, 40 delivered; 1 re-send (the in-flight record) in 6 of 7 runs, 2 in 1 run (see Open points) | pass (6/7) |
| Reboot mid-queue | `adb reboot` with 55 records left | work survives the reboot, resumes without opening the app | resumed 65 s after boot, 60 delivered, 1 re-send (in-flight) | pass |
| Airplane mode, app open | airplane on 10 s mid-run | paused notification, resumes by itself | "Synchronization Paused, 10 of 40 done", then success, 40 delivered, 1 re-send | pass |
| Wifi and data off/on, background | both off 12 s with the app at Home | paused, resumes without opening the app | paused notification, all 40, success, nothing ongoing | pass |
| System stop of a background run | run started from Home (no foreground service), charging constraint lost, then back | stop honoured, paused notification, resume | before: ongoing, not FGS; after stop: "Synchronization Paused, 6 of 40 done", 0 uploads while stopped; resumed, 0 re-sends, success | pass |
| Re-promotion when visible | run started from Home, then the app opened | becomes a foreground service | not FGS in background, FGS 8 s after opening (WorkManager restarts the run as foreground, no duplicates) | pass |
| HTTP 500 and 413 | 10 records, 500 on one, 413 on another | queue continues, 2 failed, finished-with-errors notification; next run sends only those 2 | 8 delivered, 2 failed with the HTTP body in `Error`, "2 of 10 items were rejected..."; second run: each id delivered exactly once | pass |
| 503 every 4th + slow | 12 records, 503 on every 4th request, 1.5 s delay on every 3rd | 3 failed, 9 completed | 3 failed, 9 completed | pass |
| Dropped connection | server destroys the socket on one record once | transient, retried, delivered once | `Upload Exception: unexpected end of stream`, retried by WorkManager, 8 completed, each once | pass |
| Server timeout | server never answers one request | read timeout (5 min), retry | failed after 301 s with `Upload Exception: timeout`, retried, 3 completed | pass |
| cancelSync, sync again | cancel after 8 of 30, then `enqueueSync` | stops, no notification left; then no duplicates, nothing lost | 10 at cancel, 10 four seconds later, no notification; 30 completed, each once | pass |
| Enqueue during a run | 10 more records and two `enqueueSync` calls mid-run | all sent once, the run is not restarted | 30 delivered, 0 duplicates, 1 started event | pass |
| removeRecords during a run | remove 6 not-yet-sent records | never sent | 14 delivered, none of the removed | pass |
| clearQueue during a run | clear after 3 sent | at most the in-flight one more, no empty payloads | 4 at clear, 5 after (in flight), 0 empty payloads, table empty | pass |
| removeRecords/clearQueue after a run | | rows removed | 2 of 4 left, then 0 | pass |
| Duplicate record ids | same id enqueued twice | one row, latest payload, sent once | 1 row, sent once with the second payload | pass |
| enableNotifications false | 10 records | no notification at any time | none seen (sampled every 0.7 s) | pass |
| POST_NOTIFICATIONS denied | permission revoked | sync completes, no crash | 10 completed, no crash, no notifications shown; `requestNotificationsPermission` errors with "Permission DENIED" | pass |
| syncOnlyOnWifi | wifi off, data on, then wifi on | nothing on cellular | 0 on cellular, 5 after wifi on | pass |
| syncOnlyWhenCharging | battery unplugged, then charging | nothing on battery | 0 on battery, 5 when charging | pass |
| encryptDatabase | init with encryption, sync, raw query, inspector | file not plain SQLite, all works | header is not `SQLite format 3`, 5 completed, raw query OK, inspector opens | pass |
| autoDeleteCompleted | 5 records | rows deleted after upload (getSyncedRecords empty is expected) | 5 delivered, 0 rows | pass |
| Downloads | REST GET, REST POST, absolute URL, 2 binary files (1.5 and 3 MB), one 404 | 5 completed, 404 failed, md5 match, events | as expected; events `started_download`, `progress_download`, `failed_download` | pass |
| Downloads paging | `getCompletedDownloads` limit 2, offsets 0/2/4 | 2/2/1, hasMore true/true/false | as expected; with autoDeleteCompleted 2/2/1 and table empty | pass |
| removeDownloads, clearDownloadQueue | | 6 to 4 rows, then 0 | 4, then 0 | pass |
| PRESIGNED_URL | 4 files, handshake 500 on one, PUT 403 on another, one missing file | 2 completed with md5 match, 3 failed with clear errors | as expected | pass |
| Missing file (REST) | `filePath` that does not exist | failed, not sent | failed, `Local file not found at path: ...`, 0 requests | pass |
| file:// URL with %20 | | file found, md5 match | 50,000 bytes, md5 match | pass |
| executeRawQuery | SELECT with args, PRAGMA, UPDATE with args, lowercase select, CTE, bad SQL | all work, bad SQL errors | as expected | pass |
| openDatabaseInspector | | opens, back returns | as expected | pass |
| Large file | 60 MB, REST_PAYLOAD | delivered, md5 match, no OOM | 62,914,560 bytes in 6 s, md5 match, completed | pass |
| Empty queue | `enqueueSync` with nothing queued | no notification | none | pass |

Not run on the emulator: real radio behaviour (handover between cellular and
wifi, carrier NAT timeouts) and OEM battery savers. `cmd jobscheduler timeout`
does not stop a WorkManager 2.9 worker, so the background time limit itself
was not forced; the stop path it would take (a system stop of a background
run) is covered by the charging-constraint scenario.

## Open points

- A hard kill (`kill -9`) or a dropped connection can re-send the record that
  was in flight, because the device cannot tell whether the server stored it.
  The backoffice treats a record id as idempotent; real servers should too
  (docs/retry-policy.md says so). In one of seven process-kill runs a second
  record was re-sent after the restart; six other runs (three of them run
  back to back to try to reproduce it) did not show it. The cause was not
  found; the logcat of that run was not kept.
- When a background run is promoted after the app is opened, WorkManager stops
  it and starts the same work again as a foreground run. The paused
  notification can flash for a moment. No record is sent twice.
- The foreground service type is `dataSync`. Android 15+ limits `dataSync`
  foreground services to 6 hours per day; WorkManager 2.9 does not handle that
  timeout. Not reachable in these tests.
