# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
