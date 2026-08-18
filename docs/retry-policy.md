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

* **Transient Error Detection:** The native worker inspects the HTTP execution errors. It marks a failure as **transient** if it detects:
  * Network timeouts (`SocketTimeoutException`, etc.)
  * Connection or protocol drops (`ConnectException`, `SocketException`)
  * DNS resolution failures (`UnknownHostException`, `NoRouteToHostException`)
  * Transient server errors (HTTP statuses `503 Service Unavailable` or `504 Gateway Timeout`)
* **Rescheduling (`Result.retry()`):** Instead of terminating with a hard failure, the worker returns `Result.retry()`.
* **OS Constraints & Backoff:** WorkManager puts the task into a queue and applies:
  * **Network Constraint:** The task will **not** attempt to run again until the OS detects the device is online (satisfying the `NetworkType.CONNECTED` or `NetworkType.UNMETERED` constraint).
  * **Exponential Backoff:** Retries are delayed using an exponential backoff formula (starting at 10 seconds), preventing battery drain and avoiding server DDoS conditions.
* **App State Independence:** This mechanism runs natively. The retries will occur even if the user closes the application or locks their device.

### 2. iOS & WebView (Frontend Connectivity Listener)
Because iOS does not allow suspended apps to wake up immediately upon network changes, the plugin implements a hybrid WebView fallback listener that covers iOS and coordinates foreground recovery.

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
