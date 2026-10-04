# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Repository icon (`docs/img/icon.svg`, `icon.png`, `icon-light.svg`) and GitHub social preview image (`docs/img/social-preview.png`).

## [1.0.5] - 2026-10-04

### Fixed

- Android: the progress notification no longer freezes when a sync starts or retries while the app is in the background (Android 12+). Progress is posted with `NotificationManager` on the same notification id instead of going through the foreground service on every record.
- Android: a sync running in the background is stopped and rescheduled by the system as intended (lost network or charging constraint, time limit) instead of hanging in a frozen process. The worker asks for a foreground service only while the app is visible, and again when the app is opened during a background run.
- Android: a final notification is always shown. When a run ended as a foreground service, its final notification was removed together with the progress notification.
- Android: one final notification per run (success, finished with errors, suspended, or paused), instead of a success message after a run where the server rejected items and one alert per rejected item. No ongoing notification is left behind, and an empty queue posts nothing.
- Android: `enqueueSync` while a sync is running no longer cancels and restarts it; records enqueued during a run are sent by that run.
- Android and iOS: records removed with `removeRecords` or `clearQueue` while a sync is running are no longer sent (Android sent them with an empty payload).
- Android: `REST_PAYLOAD` uploads stream the file while encoding it to Base64. A 60 MB file used to fail with `OutOfMemoryError` and stay pending.
- Android: a record whose `filePath` does not exist is marked `failed` ("Local file not found at path: ...") instead of being sent without its file and marked `completed`. `file://` paths with percent-encoded characters are decoded.
- Android: `cancelSync` sends the documented `onFailed` event ("Synchronization cancelled by user") once, with the number of records sent before the cancellation. No event for system stops or for `enqueueSync` during a run.
- Android and iOS: `executeRawQuery` returns rows for `WITH` queries (and `PRAGMA` on iOS). iOS also reports failing statements, such as a UNIQUE constraint violation, as errors and no longer returns garbled error text.
- iOS: `enqueueRecord`, `enqueueDownload`, `getCompletedDownloads` and `initialize` no longer crash when a value the API documents as text is a number or `null` (for example `id: 123`, `{ limit: null }`, a `null` header value); numbers are stored as text, as on Android.
- iOS: turning `encryptDatabase` on for an existing unencrypted database no longer leaves every call failing with "out of memory"; the database is recreated as documented.
- iOS: memory no longer grows with each record during a sync (1.47 GB to 56 MB for 336 photos), and `REST_PAYLOAD` uploads are streamed from disk instead of built in memory (a 70 MB file: 355 MB to 56 MB).
- iOS: calling `sync()` while a sync is running no longer reports "Synchronization cancelled by user"; the running sync also takes the records queued since it started.
- iOS: when the background time runs out, the sync pauses and resumes when the app returns to the foreground, instead of risking a second concurrent run and duplicate uploads.
- iOS: after a connectivity failure the sync retries on its own while the app is running (after 10 s, doubling up to 5 min) and when the app returns to the foreground.
- iOS: progress notifications are delivered during a sync (they were replaced before they could fire) and update silently in Notification Center.
- iOS: the Database Inspector is released when closed (each open used to keep a web view and its web content process alive).
- The documented `onStarted_download`, `onProgress_download` and `onFailed_download` listeners now fire; the camelCase names still work.
- Database Inspector: table rows stay readable at phone widths.

### Changed

- Android: upload events match iOS. `onProgress` fires after each successful upload with `completedCount` = records sent so far (1..N), `onFailed` carries the records sent so far, and `onCompleted` counts the items that succeeded. Up to 1.0.4 Android fired `onProgress` before each upload with the position of the record. Download progress still fires before each download on both platforms.
- Android: progress notification updates are limited to one per second and shown at once (Android 12+ may otherwise hold back a foreground service notification for 10 s), and per-item HTTP errors are summarized in the final notification.
- Android: when a connection fails while Android reports no usable network, the worker waits up to 5 minutes for it and retries the same record.
- iOS: the plugin no longer adds the `fetch` and `processing` background modes to the app's `Info.plist`; its iOS code never used them. The sync runs in the foreground, continues for the short background window iOS grants (about 30 seconds), then pauses and resumes when the app returns or calls `sync()`, with nothing lost. Apps that use these modes for their own code must declare them themselves.
- Docs: `autoDeleteCompleted` also deletes each upload once it is sent (behaviour on both platforms); Android notification lifecycle, retry and background limits; iOS background limits, retry, memory and notification behaviour; event counts.

### Added

- Android: optional notification texts `partialTitle`, `partialBody` (`{failed}`, `{total}`, `{error}`), `pausedTitle`, `pausedBody` and `waitingForNetworkBody`.
- `examples/field-audit-demo`: a runnable demo app (Android and iOS simulator) and backoffice that sync a 336-photo audit through the plugin, with automated Android tests (`tests/`, backoffice fault injection) and iOS tests (`tests/ios`, optional backoffice test API with `TEST_API=1`).

### Removed

- iOS: `UIBackgroundModes` `fetch` and `processing` from `plugin.xml` (unused by the plugin; see Changed).

## [1.0.4] - 2026-09-23

### Fixed

- iOS: `removeRecords`/`removeDownloads` no longer crash the app when the JS side passes an array containing `null` (or any other non-string element) as a record ID. Such elements are now skipped instead of causing an `NSInvalidArgumentException` (`-[NSNull UTF8String]: unrecognized selector`) while iterating the array.

## [1.0.3] - 2026-09-23

### Fixed

- Android and iOS: a single failed upload or download no longer blocks the rest of the queue. Only a genuine connectivity failure (timeout, DNS failure, no network) aborts the run early; an HTTP error response (the server was reached and rejected that specific record) now just marks that one record `failed` and the queue moves on to the next item.
- iOS: the upload path now distinguishes a connectivity failure from an HTTP error response, the same way the download path and both Android paths already did.

## [1.0.2] - 2026-09-22

### Added

- Database Inspector: connection config panel (server URL, masked headers, encryption status) shown up front, to catch misconfiguration without digging through a raw HTTP error body.
- Database Inspector: per-row **Retry** action — resets a record to `pending` and clears its last error, without waiting for the rest of the queue.
- Database Inspector: status filter chips (All/Pending/Failed/Completed) with live counts per tab.
- Database Inspector: large `Payload`/`Error`/`ResponseData` values are truncated (head+tail, with an omitted-byte count) in both the list view and JSON export, with a **View full** button that fetches the untruncated single record on demand.
- Database Inspector: copy-to-clipboard button next to each record's `Id`.

### Fixed

- Database Inspector: header no longer sits partially under the system status bar / notch on edge-to-edge layouts (Android 15+ targetSdk, iOS notch/Dynamic Island) — now reserves space via `env(safe-area-inset-top)`, with a plain fallback for WebViews that don't support it.

## [1.0.1] - 2026-09-22

### Fixed

- iOS: declare the SQLCipher CocoaPods dependency with the `<podspec>` tag instead of the removed `<framework type="podspec">` syntax. Fixes plugin installation on cordova-ios 7+ (e.g. MABS 10+ Cordova builds in OutSystems 11). Capacitor builds are unaffected.

## [1.0.0] - 2026-08-18

### Added

- Initial public release of BackgroundSyncPlugin.
- Native background sync engine for Android (WorkManager) and iOS (NSURLSession background sessions).
- Private, optionally SQLCipher-encrypted SQLite queue (`bg_sync.db`) for upload and download records.
- JavaScript API: `initialize`, `sync`/`enqueueSync`, `cancelSync`, `enqueueRecord`, `enqueueDownload`, queue inspection/removal methods, and real-time progress listeners.
- Native Database Inspector UI (Android and iOS) for manual queue recovery and debugging.
- Support for REST payload and presigned-URL upload/download strategies.
- Automatic network retry and recovery policy for transient failures.
