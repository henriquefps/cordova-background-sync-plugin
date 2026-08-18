# Bypassing the 60s WebView Timeout

This document explains how the **BackgroundSyncPlugin** bypasses the standard 60-second execution and network timeouts inherent to hybrid mobile environments.

---

## The 60-Second Timeout Problem

In typical hybrid mobile environments (JavaScript-based WebViews), network requests made directly from JS have a strict timeout limit (typically 60 seconds). Furthermore, if a user minimizes the app, locks their device, or transitions to another application, the operating system aggressively suspends the JavaScript engine, instantly killing ongoing HTTP requests.

This plugin completely bypasses and overcomes this limitation by shifting the sync execution entirely to native operating system layers.

---

## How It Works Under the Hood

### 1. Decoupled Execution
The plugin delegates all request handling to the native layer (Kotlin/Java on Android and Objective-C on iOS). Requests occur 100% isolated and silently from the WebView's JavaScript engine.

### 2. Android WorkManager & Foreground Services
On Android, the task is executed by the native `WorkManager` API. When started:
* It spins up a native **Foreground Service**, displaying a real-time progress bar in the device's notification tray.
* By using a Foreground Service, the standard 10-minute background task limit on Android is bypassed. The operating system treats the app as active for data synchronization, keeping it alive transparently.

### 3. iOS Background Task Assertions
On iOS, the task uses `UIBackgroundTaskIdentifier` to register an active background execution task with the OS:
* The OS allocates a dedicated background thread for the task.
* Even if the user locks the device, the HTTP connections remain open.
* Transmission uses native socket streams, preventing JavaScript-level interruptions.

### 4. Native Data Transmission
Even if a media upload takes longer than 60 seconds due to a weak cellular connection (e.g., 2G/3G/4G in remote areas), the mobile OS will keep the HTTP connection open until the server responds. **Downloads** (`REST_PAYLOAD` and `BINARY_FILE`) explicitly set a 5-minute connect/read timeout on both platforms. **Uploads** (`REST_PAYLOAD` and `PRESIGNED_URL`) do not set an explicit timeout at all — the connection is only bounded by the underlying OS/socket default (effectively unbounded) or by the overall background execution budget described above.

---

## Key Benefits

* **Long-Running Uploads:** Upload heavy photo folders or PDF schematics over slow networks without worrying about connection timeouts.
* **Immunity to App Minimization:** Lock the screen or check emails while the plugin syncs in the background.
* **Resilience to Force Closes (Android):** Even if the app is force-closed, `WorkManager` handles the recovery and schedules resumption when the network is restored.
