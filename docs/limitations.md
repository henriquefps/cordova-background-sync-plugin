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
* **Android:** Uses 4KB streaming buffers, enabling virtually unlimited file upload sizes.
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
