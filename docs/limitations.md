# Technical Plugin Limitations & Per-Record Limits

This document outlines the native constraints, performance limitations, and maximum per-record thresholds you must observe when using the **BackgroundSyncPlugin**.

---

## Technical Limitations

### 1. Single Sequential Queue
Synchronization is strictly sequential (one record at a time based on the `Sequence` column). A very heavy binary file or an unstable network connection causing slowness will block the entire subsequent queue until it finishes or fails.

### 2. Private Database Decoupling
The plugin no longer attempts to auto-discover or write to the OutSystems application SQLite database. It runs on its own private SQLite/SQLCipher database (`bg_sync.db`) located in the native application container sandbox.
* This completely isolates sync data from OutSystems local entities.
* Developers must use the plugin's JavaScript API (`enqueueRecord`, `getQueuedRecords`, etc.) to interface with this database instead of executing direct SQL inserts/queries on OutSystems entities.

### 3. iOS Background Life-cycle
The upload loop runs inside a native background task (`beginBackgroundTaskWithName:`), not in a `BGTaskScheduler` task or a background `NSURLSession`. In practice:
* **Foreground:** the queue runs like on Android.
* **App in the background or device locked:** iOS grants about 30 seconds. On the iOS 26 simulator, uploads went on for 30 to 35 seconds after Home, then stopped. When the time runs out, the plugin stops at the next record (the record in flight finishes when the app runs again) and posts the "Sync paused" notification. Nothing is lost: the remaining records stay `pending`, and the run resumes on its own as soon as the app is in the foreground again.
* **App closed (swiped away or killed):** the queue stops with the process. Completed records stay completed; the next `sync()` continues with the rest. At most the record that was in flight when the app died is sent again.
* Unlike Android's WorkManager, nothing restarts the queue while the app is not running.

> [!NOTE]
> **Memory use (iOS)**
> `REST_PAYLOAD` uploads write the request body (JSON with the base64 file) to a temporary file in chunks and stream it, so memory use does not grow with the file size (a 70 MB file: 56 MB app footprint during the upload). The temporary file needs free storage of about 1.35 times the file size while the record is sent. `PRESIGNED_URL` uploads stream the file itself and also avoid the base64 overhead on the wire.

---

## Maximum Limits per Synchronized Record

To ensure the synchronization stream does not cause memory leaks or crashes on the mobile devices or the web server, it is crucial to observe the following technical limits:

### 1. JSON Payload Text Limits
SQLite supports up to 1GB of text data in the `Payload` column. However, serializing massive JSON strings hurts mobile JavaScript serialization/deserialization performance and increases network transfer times. 
* **Recommendation:** Limit the JSON payload text to a maximum of **5MB - 10MB** per record.

### 2. Media / Files Size Limits
* **Android:** Uses 4KB streaming buffers, enabling virtually unlimited file upload sizes.
* **iOS:** `REST_PAYLOAD` uploads are streamed from disk (see above), so the file size is limited by the server, the network and, in the background, the 30-second window rather than by memory. Tested with 20 MB and 70 MB files on the simulator. For large files, `PRESIGNED_URL` still sends a third less data.

### 3. Server Configuration Gates
Web servers hosting exposed endpoints (e.g. IIS, Nginx) have a default upload limit per request. Uploads exceeding this threshold will fail at the server gate unless adjusted within the server configuration files.

#### Recommended Server Adjustments (web.config example for IIS)
To support robust native uploads of large media files up to 100MB, adjust your IIS server configuration by adding:

```xml
<system.web>
  <!-- Increase upload limit to 100MB -->
  <httpRuntime maxRequestLength="102400" executionTimeout="3600" />
</system.web>

<system.webServer>
  <security>
    <requestFiltering>
      <!-- Map the corresponding limit in bytes (100MB) -->
      <requestLimits maxAllowedContentLength="104857600" />
    </requestFiltering>
  </security>
</system.webServer>
```
