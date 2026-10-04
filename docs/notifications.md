# Live Progress & Status Notifications

The **BackgroundSyncPlugin** features native notification integration to keep users informed of background synchronization progress without requiring them to stay inside the application.

---

## Notification Types & Behavior

To ensure a non-intrusive user experience, notifications are split into two categories based on how they draw the user's attention:

### 1. Silent Progress Notifications
During an active synchronization loop, the plugin updates the progress tray frequently (e.g., *Sincronizando: 3 de 10 registros (30%)*).
* **Android Implementation:** Progress notifications are sent to a dedicated channel (`localstorage_sync_progress_channel`) configured with **`IMPORTANCE_LOW`**. This means the progress bar updates silently without making sound, vibrating, or interrupting the user.
* **iOS Implementation:** Each progress update replaces the previous one in Notification Center, without sound or banner (passive interruption level, iOS 15+), at most once per second. iOS shows notifications only while the app is in the background; in the foreground they go straight to Notification Center.

### 2. Alert Notifications (With Sound & Vibration)
Critical changes in synchronization states emit alerts to notify the operator that the process is finished or suspended.
* **Triggers:**
  * **Sync Complete:** All records in the queue were uploaded successfully.
  * **Sync Suspended:** The queue stopped uploading due to a network dropout (waiting for retry) or a manual cancellation.
  * **Limit Reached:** The OS background execution window has expired (iOS background limit).
* **Android Implementation:** Sent via `localstorage_sync_alerts_channel` configured with **`IMPORTANCE_DEFAULT`**, triggering standard ringtones and vibration feedback.
* **iOS Implementation:** Emits the standard system alert sound (`[UNNotificationSound defaultSound]`) and triggers hardware vibration.

---

## Configuration Options

Notifications can be fully enabled, disabled, or customized with localizations during the `initialize` call.

### 1. Toggling Notifications
Use the `enableNotifications` boolean parameter. If set to `false`, no native notifications or channels will be created or displayed during execution.

```javascript
syncEngine.initialize({
    serverUrl: "https://yourcompany.com",
    enableNotifications: true // Set to false to disable all background notifications
}, successCallback, errorCallback);
```

### 2. Custom Translations & Texts
You can define custom strings for titles and body texts using placeholders:
* `{current}`: The index of the current item being processed.
* `{total}`: The total number of items in the current sync queue.
* `{percentage}`: The overall progress percentage (0 - 100).
* `{error}`: The error description in case of failures.

```javascript
syncEngine.initialize({
    serverUrl: "https://yourcompany.com",
    enableNotifications: true,
    notificationTexts: {
        progressTitle: "Syncing Data",
        progressBody: "Sending: {current} of {total} items ({percentage}%)",
        preparingBody: "Preparing database synchronization...",
        successTitle: "Synchronization Complete",
        successBody: "All offline records successfully uploaded.",
        failureTitle: "Synchronization Suspended",
        failureBody: "Sync failed: {error}. Will retry automatically."
    }
}, successCallback, errorCallback);
```

---

## OS Permission Requirements

### Android 13+ (API 33+)
Android requires explicit user permission to post notifications. The plugin exposes a helper method to request permission at runtime:

```javascript
syncEngine.requestNotificationsPermission(
    function(granted) {
        console.log("Notification permissions granted:", granted);
    },
    function(error) {
        console.error("Failed to request permissions:", error);
    }
);
```

### iOS
On iOS, `requestNotificationsPermission()` shows the system prompt for alerts and sounds (`UNAuthorizationOptionAlert | UNAuthorizationOptionSound`) the first time and resolves with `true` or `false`; later calls resolve with the stored answer without a prompt. If the app never calls it, the plugin asks when it posts its first notification, which is at the start of the first sync. If the user declines, the sync runs the same, without notifications.
