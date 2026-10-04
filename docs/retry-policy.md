# Automatic Network Retry & Recovery Policy

This document outlines the behavior and implementation details of the automatic synchronization retry mechanism in the **BackgroundSyncPlugin**.

---

## Overview

Mobile networks are inherently unstable. When a background synchronization task fails due to a network drop, timeout, or server overload, the plugin is designed to suspend execution gracefully and **automatically reschedule the synchronization once the internet connection is restored**.

To achieve this while respecting battery consumption and OS limitations, the plugin combines a **native worker retry policy** (Android) with a **WebView connectivity listener** (iOS & Cross-platform).

---

## Platform Behaviors

### 1. Android (Native `WorkManager` Scheduling)
On Android, the plugin leverages the Jetpack `WorkManager` API. When a sync worker executes in the background and encounters a transient network error, it delegates rescheduling to the operating system.

* **Transient vs. per-item errors:** The worker separates two kinds of failure:
  * **Connectivity failures** (the request never reached the server or the connection dropped mid-request: timeouts, `ConnectException`, `SocketException`, `UnknownHostException`, and the same for the presigned URL handshake and upload). These are transient. If Android reports no usable network, the worker waits up to 5 minutes for it and retries the same item; otherwise the run ends with `Result.retry()`.
  * **HTTP error responses** (any 4xx or 5xx, including 503 and 504). The server was reached and rejected this record. The record is marked `failed` with the response in `Error`, a `failed` event is fired, and the run moves on to the next record. Failed records are selected again by the next run (the next `enqueueSync`, retry or WorkManager restart); they are not retried within the same run.
* **Rescheduling (`Result.retry()`):** Instead of terminating with a hard failure, the worker returns `Result.retry()`.
* **OS Constraints & Backoff:** WorkManager puts the task into a queue and applies:
  * **Network Constraint:** The task will **not** attempt to run again until the OS detects the device is online (satisfying the `NetworkType.CONNECTED` or `NetworkType.UNMETERED` constraint).
  * **Exponential Backoff:** Retries are delayed using an exponential backoff formula (starting at 10 seconds), preventing battery drain and avoiding server DDoS conditions.
* **Stopped by the system:** When the network or charging constraint is lost, or a run without a foreground service reaches the background time limit, WorkManager stops the worker. The worker finishes the item in flight, records its status, shows a "paused" notification and exits; WorkManager starts it again when the system allows it (for a lost constraint, as soon as it is met again). Measured on Android 16: 3 to 6 seconds after the network comes back.
* **`enqueueSync` while a run is in progress:** The running worker is kept (up to 1.0.4 it was cancelled and replaced). Records enqueued during a run are picked up by the same run when it reaches the end of its list, and at most one follow-up run is chained behind it for anything enqueued after its last check. This matters because the JS layer calls `enqueueSync` on every `online` event.
* **App State Independence:** This mechanism runs natively. The retries will occur even if the user closes the application or locks their device.

### 2. iOS (Native Retry While the App Runs) & WebView (Connectivity Listener)
Because iOS does not allow suspended apps to wake up upon network changes, recovery on iOS happens while the app is running:

* **Native retry with backoff:** when an upload or download fails with a connectivity error (timeout, connection lost or refused, DNS failure), the run stops and the plugin retries it after 10 seconds, then 20, 40, 80, 160 and every 300 seconds, while the app process is alive. This also covers a server that is down while the device is still online, a case the `online` event below never sees.
* **Back to the foreground:** a run interrupted by a connectivity error or by the end of the background time resumes as soon as the app becomes active.
* **`cancelSync()`** stops these automatic retries until the next `sync()`.
* An HTTP error response (4xx, 5xx) is not retried automatically on iOS: the record is marked `failed`, the rest of the queue goes on, and the record is sent again by the next `sync()`.

The WebView listener also applies, on both platforms:

* **Connectivity Listener:** The JavaScript bridge registers a global listener for browser connection changes:
  ```javascript
  window.addEventListener('online', function() { ... });
  ```
* **Auto-Trigger:** When the WebView enters the foreground or remains active, and the connection transitions from offline to online, the plugin automatically calls `enqueueSync()`.
* **Lightweight Validation:** When triggered, the native layer queries the database schema to see if there are any remaining rows with `pending` or `failed` statuses. If none are found, the sync task completes instantly, consuming virtually zero CPU/battery.

---

## Concurrency & Data Integrity Guarantees

When a retry occurs, it is critical that the plugin does not upload the same records twice (duplicate payloads). This is guaranteed directly by the private SQLite database — there is no separate preference-store or reconciliation step involved:

1. **State Persistence:** As soon as a record finishes uploading (or downloading), the native worker writes the outcome straight into the row's `Status` column (`"completed"` or `"failed"`, with the failure reason in `Error`) inside `sync_queue` / `download_queue`. This write happens synchronously per-record, before moving to the next one.
2. **Filtering on Retry:** Every worker run (initial or retried) re-reads the queue with `WHERE LOWER(Status) = 'pending' OR LOWER(Status) = 'failed' ORDER BY Sequence ASC`. Records already marked `"completed"` are never selected again, so a retry naturally resumes from the first non-completed row.
3. **No App-Side Reconciliation Needed:** Because the state lives directly in SQLite (the same database the JS API reads via `getQueuedRecords()` / `getSyncedRecords()` / `getCompletedDownloads()`), there is nothing to "commit" when the app reopens — the queue is already consistent on disk.

This ensures that even if a sync cycle of 10 items is interrupted on the 5th item, the subsequent retry will resume exactly at the 6th item without duplication.

Two cases can still send one record twice, and the server should treat a record id as idempotent:
* The connection drops after the server stored the request but before the device read the response. The device cannot tell the difference from a failed upload, so it sends that record again.
* On Android, only one worker run executes at a time in the app process: a cancelled run keeps its thread until the upload in flight returns, and the next run waits for it, so the in-flight record is never loaded by two runs at once.

Records removed with `removeRecords` or `clearQueue` while a run is in progress are skipped by that run (Android), instead of being sent with an empty payload as in 1.0.4.
