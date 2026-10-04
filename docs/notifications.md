# Live Progress & Status Notifications

The **BackgroundSyncPlugin** features native notification integration to keep users informed of background synchronization progress without requiring them to stay inside the application.

---

## Notification Types & Behavior

To ensure a non-intrusive user experience, notifications are split into two categories based on how they draw the user's attention:

### 1. Silent Progress Notifications
During an active synchronization loop, the plugin updates the progress tray frequently (e.g., *Sincronizando: 3 de 10 registros (30%)*).
* **Android Implementation:** Progress notifications are sent to a dedicated channel (`localstorage_sync_progress_channel`) configured with **`IMPORTANCE_LOW`**. This means the progress bar updates silently without making sound, vibrating, or interrupting the user. The progress is updated at most once per second (Android drops notification updates posted faster than a few per second).
* **iOS Implementation:** Each progress update replaces the previous one in Notification Center, without sound or banner (passive interruption level, iOS 15+), at most once per second. iOS shows notifications only while the app is in the background; in the foreground they go straight to Notification Center.

### 2. Alert Notifications (With Sound & Vibration)
Critical changes in synchronization states emit alerts to notify the operator that the process is finished or suspended.
* **Triggers:**
  * **Sync Complete:** All records in the queue were uploaded successfully.
  * **Sync Suspended:** The queue stopped uploading due to a network dropout (waiting for retry) or a manual cancellation.
  * **Limit Reached:** The OS background execution window has expired (iOS background limit).
* **Android Implementation:** Sent via `localstorage_sync_alerts_channel` configured with **`IMPORTANCE_DEFAULT`**, triggering standard ringtones and vibration feedback. One final notification per run replaces the progress notification (see the Android lifecycle below).
* **iOS Implementation:** Emits the standard system alert sound (`[UNNotificationSound defaultSound]`) and triggers hardware vibration.

---

## Android: Foreground Service and Notification Lifecycle

On Android the sync runs in a WorkManager worker. The progress notification and the final notification follow these rules:

1. **Foreground service when allowed.** At the start of a run the worker asks WorkManager to run it as a foreground service (`dataSync` type), which protects it from the background execution limit (about 10 minutes per run). Android 12 and later only allow this while the app is visible. A run that starts in the background (a retry after a network drop, a run resumed by WorkManager after a lost constraint or a reboot) cannot start the service.
2. **Progress never depends on the foreground service.** Progress is always posted with `NotificationManager.notify` on the same notification id. When the service is running, that id is the service's notification and it updates in place. When the service could not start, the same notification is posted as a regular ongoing notification. Up to 1.0.4 every progress update went through the foreground service call, so a run that started in the background left the notification frozen while uploads continued.
3. **Promotion when the app comes back.** A run that is not a foreground service tries again (at most every 5 seconds, at the next progress update) whenever the app is visible, so opening the app during a long background run brings back the protection.
4. **One final notification per run, nothing ongoing left behind.** When a run ends, the progress notification is removed and one final notification is posted on its own id:

| Run outcome | Notification | Texts |
| --- | --- | --- |
| Every item sent | Success (alerts channel) | `successTitle`, `successBody` |
| Queue finished, but the server rejected some items (HTTP 4xx/5xx) | Finished with errors (alerts channel). Rejected items stay queued with status `failed` and go out again on the next run. | `partialTitle`, `partialBody` (`{failed}`, `{total}`, `{error}`) |
| Connection lost (request never reached the server) | Suspended (alerts channel). WorkManager retries when the network is back. | `failureTitle`, `failureBody` (`{error}`) |
| Stopped by the system (time limit, lost network or charging constraint, quota) | Paused (silent progress channel). WorkManager resumes the run on its own. | `pausedTitle`, `pausedBody` (`{current}`, `{total}`) |
| Cancelled by the app (`cancelSync`) | None | |
| Queue was empty | None (no foreground service either). `enqueueSync` runs on every `online` event, so an empty queue must stay silent. | |

5. **Waiting for the network.** If a connection fails while Android still reports no usable network, the worker shows `waitingForNetworkBody` (an indeterminate progress) and waits up to 5 minutes for the network before retrying the same item. In practice WorkManager usually stops the worker first (network constraint) and shows the paused notification instead.

Per-item HTTP errors no longer post an alert for every rejected item during the run; the final notification summarizes them.

Two details measured on Android 16 (emulator, WorkManager 2.9.0):
* An expedited request (`setExpedited`) does not help: the worker ran as an expedited job and Android still refused to start the foreground service from the background. Expedited work also cannot have a charging constraint or a start delay, so the plugin does not use it.
* When a background run is promoted after the app is opened, WorkManager stops that run and starts the same work again as a foreground run within a few seconds. The paused notification can flash briefly. No record is sent twice: the next run waits for the item in flight.

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
* `{current}`: For uploads, the number of records sent so far in the run; for downloads, the position of the item being downloaded.
* `{total}`: The total number of items in the current sync queue.
* `{percentage}`: The overall progress percentage (0 - 100).
* `{error}`: The error description in case of failures.
* `{failed}`: Number of items the server rejected in the run (`partialBody`, Android).

Android also reads these optional keys (defaults in parentheses): `partialTitle` ("Synchronization Finished With Errors"), `partialBody` ("{failed} of {total} items were rejected by the server and stay queued for the next sync."), `pausedTitle` ("Synchronization Paused"), `pausedBody` ("{current} of {total} done. The sync resumes automatically when Android allows it."), `waitingForNetworkBody` ("Waiting for a network connection ({current} of {total} done)"). Download runs use `downloadProgressTitle`, `downloadProgressBody`, `downloadPreparingBody`, `downloadFailureTitle` and `downloadFailureBody`.

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

If the permission is denied, the sync still runs (and still uses the foreground service when allowed); Android simply does not show its notifications. Verified on Android 16.

### iOS
On iOS, `requestNotificationsPermission()` shows the system prompt for alerts and sounds (`UNAuthorizationOptionAlert | UNAuthorizationOptionSound`) the first time and resolves with `true` or `false`; later calls resolve with the stored answer without a prompt. If the app never calls it, the plugin asks when it posts its first notification, which is at the start of the first sync. If the user declines, the sync runs the same, without notifications.
