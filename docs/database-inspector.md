# Manual Recovery: The Database Inspector

This document explains the built-in recovery/debugging screen bundled with the plugin — what it's for, how to trigger it, what it shows, and what to consider before shipping it to end users.

---

## Overview

`sync_queue` and `download_queue` are private, opaque tables — there's no way for a developer or support engineer to look inside them without writing custom debug tooling into every app that consumes this plugin. The Database Inspector solves that once, inside the plugin itself: a single JS call opens a native, full-screen recovery UI (`WKWebView` on iOS, `WebView` on Android) that lets you:

- Browse every row in both `sync_queue` and `download_queue`, including columns the regular JS API doesn't expose (`Payload`, `FilePath`, `Error`, `Sequence`, `ResponseData`).
- Delete individual stuck/bad records directly from the queue.
- Export both tables as a single JSON file, so pending data can be recovered and re-imported/processed elsewhere if a device's sync is permanently stuck.

**Use case:** a field device fails to sync (network never recovers, a malformed record blocks the queue, the app is being decommissioned) — instead of losing whatever was queued, an operator or support engineer opens the inspector, exports the JSON, and hands it off for manual reconciliation.

---

## JavaScript API

```javascript
const syncEngine = window.cordova?.plugins?.BackgroundSyncPlugin;

syncEngine.openDatabaseInspector(
    (msg) => console.log("Database inspector opened:", msg),
    (err) => console.error("Failed to open database inspector:", err)
);
```

The success callback fires as soon as the native screen is presented — it does not wait for the user to close it. There is no corresponding "closed" event; the screen is self-contained and dismisses itself via its own Close button.

---

## What you can do inside

| Action | Behavior |
| :--- | :--- |
| **Browse** | Two tabs — "Sync Queue (Uploads)" and "Download Queue" — each rendering every row, most recent first. |
| **Delete** | Per-row delete button, with an in-page confirmation prompt. Deletes are immediate and irreversible — there's no undo. |
| **Export All (JSON)** | Serializes both tables (all columns, all rows) into one JSON file (`{ "syncQueue": [...], "downloadQueue": [...] }`) and hands it to the OS share sheet (iOS `UIActivityViewController`) or a file picker (Android Storage Access Framework) — no extra permission or `FileProvider` setup required from the consuming app. |

---

## Encryption

The inspector opens the database through the exact same code path as the rest of the plugin (`DatabaseHelper.getWritableDatabase` on Android, `[plugin openWritableDatabase]` on iOS), using whichever `encryptDatabase` value was set on `initialize()` and the same Keystore/Keychain-derived passphrase. In practice this means:

- If the database is encrypted, the inspector transparently decrypts it — you'll never be prompted for a key.
- The inspector **cannot** be used to verify whether the database is actually encrypted, since it's an authorized in-process reader either way. To confirm encryption, inspect the raw `bg_sync.db` file bytes outside the app (a plaintext SQLite file always starts with the `SQLite format 3\0` header; an encrypted one won't).

---

## ⚠️ Before shipping this to production

The inspector surfaces raw record contents — endpoints, payload JSON, file paths, error messages — and lets whoever opens it delete queued data outright. Nothing in the plugin gates who can call `openDatabaseInspector()`; that decision is left entirely to the consuming app. Before wiring a visible button to it in a production build, consider:

- Whether end users should ever see this, or whether it should be reachable only through an internal/support-only entry point (a hidden gesture, a debug-build flag, a support PIN screen).
- Whether the payloads your app queues could contain sensitive data that shouldn't be broadly viewable/exportable by whoever has the device.

The plugin intentionally does not make this decision for you — it exposes the capability; access control is an app-level concern.
