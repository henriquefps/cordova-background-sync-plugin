# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
