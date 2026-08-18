# Manually Cancelling Synchronization

This document explains how to use the JavaScript API to cancel a running background synchronization task, what happens to the synchronization queue under the hood, and how to resume/restart it later.

---

## Overview

The `cancelSync()` feature allows developers to instantly stop a running synchronization cycle. 

* **State Preservation:** Any records already successfully uploaded to the server before the cancellation request remain processed (and marked as `completed`).
* **Queue Safety:** Any records that were still waiting in the queue to be uploaded are left as is (`pending` or `failed`), ensuring no data is lost or skipped.
* **No Rescheduling:** Manually cancelling a sync cycle does **not** trigger the automatic retry policies (which are reserved only for transient network drops).

---

## JavaScript API

### Exposing the Cancellation
You can trigger the cancellation signal by invoking the `cancelSync` method exposed by the plugin:

```javascript
// Expose plugin instance
const syncEngine = window.cordova?.plugins?.BackgroundSyncPlugin;

if (syncEngine) {
    syncEngine.cancelSync(
        function(successMsg) {
            console.log("Sync cancel signal sent successfully:", successMsg);
        },
        function(errorMsg) {
            console.error("Failed to cancel sync:", errorMsg);
        }
    );
}
```

### Listening to the Cancellation Event
When a cancellation occurs, the registered progress listener will receive an `onFailed` event with the specific error message `"Synchronization cancelled by user"`:

```javascript
syncEngine.registerListeners({
    onStarted: (data) => {
        console.log("Sync started.");
    },
    onProgress: (progress) => {
        console.log(`Uploaded ${progress.completedCount}/${progress.totalCount}`);
    },
    onCompleted: (data) => {
        console.log("Sync finished successfully.");
    },
    onFailed: (data) => {
        if (data.error === "Synchronization cancelled by user") {
            console.log("The synchronization was cancelled manually by the operator.");
        } else {
            console.error("Sync suspended due to error:", data.error);
        }
        // Manage or clear completed records if necessary
        if (data.completedCount > 0) {
            cleanSyncedRecords();
        }
    }
});
```

---

## How to Resume/Restart Synchronization

After cancelling, the remaining items in the queue are still in their previous state (e.g. `pending` or `failed`) in the private database. You can restart the synchronization cycle at any time.

### Step 1: Manage Completed Items (If autoDeleteCompleted is False)
If `autoDeleteCompleted` was set to `false` during initialization, completed records will persist in the private SQLite database. You should query them using `getSyncedRecords()` and remove them using `removeRecords()` to keep the queue clean:

```javascript
function cleanSyncedRecords() {
    syncEngine.getSyncedRecords(
        (records) => {
            const idsToRemove = records.map(r => r.id);
            if (idsToRemove.length === 0) return;

            syncEngine.removeRecords(
                idsToRemove,
                (success) => {
                    console.log("Successfully removed completed records from private database queue.");
                },
                (err) => console.error("Failed to remove records:", err)
            );
        },
        (err) => console.error("Failed to fetch synced records:", err)
    );
}
```

### Step 2: Re-trigger the Sync Worker
Once the queue is ready, simply call `sync()` again. The plugin will automatically reset the internal cancellation flags and resume processing the remaining records:

```javascript
function restartSync() {
    console.log("Restarting background sync...");
    syncEngine.sync(
        (success) => {
            console.log("Background synchronization restarted successfully.");
        },
        (error) => {
            console.error("Failed to restart sync:", error);
        }
    );
}
```
