# Integration & Usage Guide

This guide provides a step-by-step walkthrough of how to integrate and use the **BackgroundSyncPlugin** in Cordova, Capacitor, or OutSystems Mobile applications.

---

## Architecture Flow

The plugin manages its own **private SQLite/SQLCipher database (`bg_sync.db`)** natively. This completely isolates background sync transactions from your application's business database transactions, preventing deadlock conditions.

The integration flow consists of:

1. Initializing the engine with your backend and optional database encryption.
2. Enqueuing records directly into the plugin's private queue via JavaScript.
3. Triggering synchronization (manually or automatically via network connectivity state changes).
4. Reading or clearing sync records and their states from JavaScript.

---

## Database Schema / Data Model

The private database (`bg_sync.db`) consists of a single queue table called `sync_queue` defined with the following structure:

| Column | Type | Constraints | Description |
| :--- | :--- | :--- | :--- |
| **`Id`** | `TEXT` | `UNIQUE` | Unique identifier generated for the record (or provided via JS). |
| **`Sequence`** | `INTEGER` | `PRIMARY KEY AUTOINCREMENT` | Auto-incrementing order key ensuring strictly sequential processing. |
| **`Endpoint`** | `TEXT` | - | Relative target API path (e.g. `/api/v1/sync`). |
| **`Payload`** | `TEXT` | - | Serialized JSON data containing metadata/form attributes. |
| **`FilePath`** | `TEXT` | - | Local file URI (e.g. `file://...`) pointing to an attachment (optional). |
| **`UploadStrategy`** | `TEXT` | - | Upload strategy used: `"REST_PAYLOAD"` (default) or `"PRESIGNED_URL"`. |
| **`Status`** | `TEXT` | - | Current synchronization status: `"pending"`, `"failed"`, or `"completed"`. |
| **`Error`** | `TEXT` | - | Detailed exception message if the last synchronization attempt failed. |

---

## Step 1: Initialize the Sync Engine

Call the `initialize` method during app startup. The engine will configure the native background task schedulers and set up the local queue database.

To enable database encryption, set `encryptDatabase` to `true`. The plugin will automatically generate and securely store a unique passphrase in **Android Keystore** and **iOS Keychain**.

```javascript
const syncEngine = window.cordova?.plugins?.BackgroundSyncPlugin;

if (syncEngine) {
    syncEngine.initialize(
        {
            serverUrl: "https://yourcompany.api.com", // Base server domain
            syncOnlyOnWifi: false,                     // Android: require Wi-Fi
            syncOnlyWhenCharging: false,               // Android: require charger
            enableNotifications: true,                 // Show native progress notifications
            autoDeleteCompleted: true,                // Auto-deletes completed DOWNLOADS only — see note below
            encryptDatabase: true,                     // Enable SQLCipher encryption (Keystore/Keychain)
            headers: {
                "Authorization": "Bearer eyJhbGciOi...",
                "X-Custom-Header": "custom-value"
            },
            notificationTexts: {
                progressTitle: "Syncing Data",
                progressBody: "Sending: {current} of {total} items ({percentage}%)",
                preparingBody: "Preparing database synchronization...",
                successTitle: "Synchronization Complete",
                successBody: "All offline records successfully uploaded.",
                failureTitle: "Synchronization Suspended",
                failureBody: "Sync failed: {error}. Will retry automatically."
            }
        },
        function(success) {
            console.log("Sync engine initialized:", success);
            registerProgressListeners(); // Set up event hooks
        },
        function(error) {
            console.error("Failed to initialize engine:", error);
        }
    );
}
```

> [!NOTE]
> **`autoDeleteCompleted` only affects `download_queue`.** When `true`, `getCompletedDownloads()` deletes each record it returns (see [Background Downloads Guide](background-downloads.md)). It has **no effect on `sync_queue`** — completed uploads always persist until you explicitly call `removeRecords()`, regardless of this setting. See [Manually Cancelling Synchronization → Managing Completed Uploads](cancel-sync.md#step-1-managing-completed-uploads) for the cleanup pattern this implies.

---

## Step 2: Register Progress Listeners

Register event listeners to track the real-time background progress when the application is active in the foreground. There are **7 events** in total — 3 for the upload cycle, 3 for the download cycle, and one shared `onCompleted` that fires once at the very end of the **combined** run (uploads, then downloads):

| Event | Fires when | Payload |
| :--- | :--- | :--- |
| `onStarted` | The upload queue starts processing | `{ event, totalCount }` |
| `onProgress` | Periodically during upload | `{ event, percentage, completedCount, totalCount }` |
| `onFailed` | Upload sync suspended (network drop or `cancelSync()`) | `{ event, percentage, completedCount, totalCount, error }` |
| `onStarted_download` | The download queue starts processing | `{ event, totalCount }` |
| `onProgress_download` | Periodically during download | `{ event, percentage, completedCount, totalCount }` |
| `onFailed_download` | Download sync suspended | `{ event, percentage, completedCount, totalCount, error }` |
| `onCompleted` | **Once**, after the entire run finishes (uploads *and* downloads) | `{ event, percentage, completedCount, totalCount }` |

> [!IMPORTANT]
> There is **no `onCompleted_download`**. Unlike the other three, `onCompleted` is not split per direction — it fires exactly once per `sync()` run, after both queues have been drained, with `completedCount`/`totalCount` covering uploads and downloads combined. Don't wait for a separate "downloads finished" signal; it doesn't exist.

```javascript
function registerProgressListeners() {
    syncEngine.registerListeners({
        // Upload cycle
        onStarted: (data) => {
            console.log(`Upload sync started. Total records: ${data.totalCount}`);
        },
        onProgress: (progress) => {
            console.log(`Upload progress: ${progress.percentage}% (${progress.completedCount}/${progress.totalCount})`);
            loadSyncQueueStatus(); // Refresh UI list
        },
        onFailed: (data) => {
            console.error("Upload sync suspended:", data.error);
            loadSyncQueueStatus();
        },
        // Download cycle
        onStarted_download: (data) => {
            console.log(`Download sync started. Total records: ${data.totalCount}`);
        },
        onProgress_download: (progress) => {
            console.log(`Download progress: ${progress.percentage}% (${progress.completedCount}/${progress.totalCount})`);
        },
        onFailed_download: (data) => {
            console.error("Download sync suspended:", data.error);
        },
        // Combined — fires once, after both queues are drained
        onCompleted: (data) => {
            console.log(`Sync run complete! ${data.completedCount} total items processed.`);
            loadSyncQueueStatus();
        }
    });
}
```

---

## Step 3: Enqueue Records & Trigger Sync

Whenever an operator performs an offline action, pass the upload parameters to the native queue database using `enqueueRecord`:

```javascript
function saveOfflineRecord(formData, attachedFileUri) {
    const record = {
        id: Date.now().toString(),                      // Optional. Generated automatically if omitted.
        payload: formData,                               // Object, array, or string payload.
        endpoint: "/api/v1/sync/inspections",            // Relative target API path.
        filePath: attachedFileUri || null,               // Local file URI (optional, e.g. file://...)
        uploadStrategy: "REST_PAYLOAD"                   // "REST_PAYLOAD" (default) or "PRESIGNED_URL"
    };

    // 1. Add to the native queue database
    syncEngine.enqueueRecord(
        record,
        (res) => {
            console.log(`Record enqueued. ID: ${res.id}, Status: ${res.status}`);
            
            // 2. Trigger native sync worker
            syncEngine.sync(
                (msg) => console.log("Native sync scheduler active:", msg),
                (err) => console.error("Failed to schedule sync:", err)
            );
        },
        (err) => console.error("Enqueue failed:", err)
    );
}
```

---

## Step 4: Querying Sync Status & Managing Records

You can query the current queue status or delete records directly via JavaScript:

### Fetch Unsynchronized Records (Pending & Failed)

```javascript
syncEngine.getQueuedRecords(
    (records) => {
        // Returns: [{ id: "123", status: "pending", error: "" }, { id: "124", status: "failed", error: "Timeout" }]
        console.log("Queued records:", records);
    },
    (err) => console.error("Query failed:", err)
);
```

### Fetch Successfully Synchronized Records

```javascript
syncEngine.getSyncedRecords(
    (records) => {
        // Returns: [{ id: "121", status: "completed" }]
        console.log("Synced records:", records);
    },
    (err) => console.error("Query failed:", err)
);
```

### Delete Specific Records

```javascript
const idsToRemove = ["121", "122"];
syncEngine.removeRecords(
    idsToRemove,
    (success) => console.log("Records deleted from queue database."),
    (err) => console.error("Delete failed:", err)
);
```

### Clear All Records (Purge Database)

```javascript
syncEngine.clearQueue(
    (success) => console.log("All sync queue data purged."),
    (err) => console.error("Purge failed:", err)
);
```

---

## Step 5: Platform-Specific Requirements

### 1. OutSystems Mobile Setup

Since the plugin's [plugin.xml](file:///../plugin.xml) automatically injects the required iOS background modes (`fetch` and `processing`) and Android permissions into the generated native packages, **no manual configuration of background capabilities is required** inside OutSystems.

You only need to reference the plugin's Git repository in your OutSystems module's **Extensibility Configurations**:

```json
{
    "plugin": {
        "url": "https://github.com/henriquefps/cordova-background-sync-plugin.git"
    }
}
```

### 2. Android Permissions (Android 13+)

On Android 13+, call `requestNotificationsPermission()` during the app onboarding process to ensure users see progress notifications.

---

## Background Downloads (Delta Sync)

For implementing downstream background synchronization (retrieving server updates, metadata delta responses, and remote media files offline), check the dedicated [Background Downloads & Delta Sync Guide](file:///Users/henriquefps/Documents/work-apps/outsystems-background-sync-plugin/docs/background-downloads.md).
