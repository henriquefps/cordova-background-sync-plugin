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

### 3. Android Background Execution
The Android worker runs under WorkManager. Android 12 and later only let it become a foreground service while the app is visible, so a run that starts in the background (a retry after a network drop, a run resumed after a lost constraint or a reboot) runs as a regular background job:
* It is limited to about 10 minutes per execution. When the system stops it, the worker finishes the item in flight, shows a "paused" notification and WorkManager starts it again later; no item is lost or sent twice because of the stop.
* The progress notification still updates (it is posted directly, not through the foreground service), and the worker becomes a foreground service again as soon as the app is opened.
* WorkManager also stops a foreground run when its network or charging constraint is lost, so after an airplane-mode cut the rest of the run is a background run.
* Force-stopping the app (Settings, or `adb shell am force-stop`) cancels its scheduled work until the app is opened again; this is an Android rule. Swiping the app from recents, killing its process or rebooting the device does not lose the queue: WorkManager runs the work again by itself.

### 4. iOS Background Life-cycle
The upload loop runs inside a native background task assertion (`UIBackgroundTaskIdentifier`). If the user minimizes the app or locks the device, the native thread will continue execution in the background for a prolonged period (usually up to 1-3 minutes) before being gracefully suspended by the OS to prevent battery drain.

> [!WARNING]
> **Critical alert on RAM consumption (iOS)**
> When using the standard `REST_PAYLOAD` upload strategy, the native iOS implementation loads the entire media file to be uploaded into the device's RAM at once (`[NSData dataWithContentsOfFile:...]`) to convert it to Base64. Extremely large video files or uncompressed photos can trigger an Out-Of-Memory (OOM) crash, causing the OS to terminate the application.
> * **Bypass Recommendation:** Use the `PRESIGNED_URL` upload strategy, which uses `NSInputStream` to stream binary data directly from storage in chunks without loading the entire file into RAM.

---

## Maximum Limits per Synchronized Record

To ensure the synchronization stream does not cause memory leaks or crashes on the mobile devices or the web server, it is crucial to observe the following technical limits:

### 1. JSON Payload Text Limits
SQLite supports up to 1GB of text data in the `Payload` column. However, serializing massive JSON strings hurts mobile JavaScript serialization/deserialization performance and increases network transfer times. 
* **Recommendation:** Limit the JSON payload text to a maximum of **5MB - 10MB** per record.

### 2. Media / Files Size Limits
* **Android:** Both strategies stream the file. `REST_PAYLOAD` encodes it to Base64 while writing the request body (fixed-length streaming, 64 KB buffers), so memory use does not grow with the file size; up to 1.0.4 it read the whole file and built the JSON body in memory (about 4 times the file size) and a 60 MB file crashed the worker with `OutOfMemoryError`. Verified with a 60 MB file on Android 16. Base64 still adds a third to the bytes on the wire, so `PRESIGNED_URL` remains the better choice for large media. A `filePath` that does not exist now marks the record `failed` ("Local file not found at path: ...") instead of sending the payload without the file.
* **iOS:** Individual media uploads must be limited to a maximum of **50MB** to prevent OOM termination.

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
