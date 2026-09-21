# Background Downloads Guide

The **BackgroundSyncPlugin** supports reliable, background-compatible file and payload downloading. This guide explains how to construct offline synchronization architectures using **Delta Sync (Delta A)** patterns.

---

## The Delta Sync Pattern (Delta A)

When building offline-first systems, downloading the entire database is inefficient. Instead, follow this pattern:

1. **Client Stores Last Sync Time**: Keep a timestamp (e.g. `lastSyncTime`) in the local application storage.
2. **Delta Handshake**: Fetch a lightweight metadata response containing only records created or modified since the `lastSyncTime`.
3. **Queue Downloads**:
   - For metadata payloads: Enqueue requests using `REST_PAYLOAD` strategy.
   - For attachments: Enqueue requests using `BINARY_FILE` strategy.
4. **Processing**: The background engine automatically retrieves JSON files, stores them in the encrypted local database, and streams binary files to safe sandbox directories.
5. **UI Integration**: Once downloads complete, parse JSON metadata changes, update local UI databases, and reference local paths for offline media.

---

## Database Schema (`download_queue`)

The private database contains a dedicated `download_queue` table defined as:

| Column | Type | Constraints | Description |
| :--- | :--- | :--- | :--- |
| **`Id`** | `TEXT` | `UNIQUE` | Unique identifier generated for the download request. |
| **`Sequence`** | `INTEGER` | `PRIMARY KEY AUTOINCREMENT` | Auto-incrementing order key ensuring strictly sequential downloads. |
| **`Endpoint`** | `TEXT` | - | Relative endpoint path or absolute URL of target resource. |
| **`Payload`** | `TEXT` | - | Serialized request body parameters (e.g. JSON query filters). |
| **`FilePath`** | `TEXT` | - | Absolute target destination path where binary files will be streamed. |
| **`DownloadStrategy`** | `TEXT` | - | Strategy used: `"REST_PAYLOAD"` (JSON results) or `"BINARY_FILE"`. |
| **`Status`** | `TEXT` | - | Current status: `"pending"`, `"failed"`, or `"completed"`. |
| **`ResponseData`** | `TEXT` | - | Contains raw text or JSON response returned by the server on success. |
| **`Error`** | `TEXT` | - | Detailed exception message if download failed. |

---

## JavaScript API Reference

### 1. Enqueue a Download

```javascript
const syncEngine = window.cordova?.plugins?.BackgroundSyncPlugin;

syncEngine.enqueueDownload(
    {
        id: "delta_metadata_1",
        endpoint: "/api/sync/delta?lastSyncTime=2026-06-20T12:00:00Z",
        payload: "",
        downloadStrategy: "REST_PAYLOAD" // Saves JSON response inside the DB
    },
    (res) => console.log("Download enqueued:", res),
    (err) => console.error("Enqueue download failed:", err)
);

// Enqueue file streaming:
syncEngine.enqueueDownload(
    {
        id: "pdf_attachment_102",
        endpoint: "http://localhost:5001/static/uploads/sample.pdf",
        filePath: "cdvfile://localhost/temporary/inspections/sample.pdf", // Resolved dynamically
        downloadStrategy: "BINARY_FILE" // Streams directly to disk
    },
    (res) => console.log("File download enqueued:", res),
    (err) => console.error("Enqueue file failed:", err)
);

// Enqueueing only writes to the local download_queue — it does not start
// processing by itself. Trigger the same native worker used for uploads:
syncEngine.sync(
    (msg) => console.log("Native sync scheduler active:", msg),
    (err) => console.error("Failed to schedule sync:", err)
);
```

> [!NOTE]
> There is no separate `syncDownloads()` method. A single `sync()` call schedules one native background run that drains `sync_queue` (uploads) first and then `download_queue` (downloads).

### 2. Listen for Real-Time Download Progress

The download cycle has its own 3 events — `onStarted_download`, `onProgress_download`, `onFailed_download` — separate from the upload ones. Completion is shared: a single `onCompleted` fires once, after *both* queues finish, not once per queue.

```javascript
syncEngine.registerListeners({
    onStarted_download: (data) => {
        console.log(`Download sync started. Total: ${data.totalCount}`);
    },
    onProgress_download: (progress) => {
        console.log(`Download progress: ${progress.percentage}% (${progress.completedCount}/${progress.totalCount})`);
    },
    onFailed_download: (data) => {
        console.error("Download sync suspended:", data.error);
    },
    onCompleted: (data) => {
        // Fires once the whole run (uploads + downloads) is done — not download-specific.
        console.log(`Sync run complete. ${data.completedCount} total items processed.`);
    }
});
```

Full 7-event reference (payload shapes, upload vs. download vs. shared): [Integration Guide → Register Progress Listeners](integration-guide.md#step-2-register-progress-listeners).

### 3. Fetch Queued Downloads

```javascript
syncEngine.getQueuedDownloads(
    (records) => {
        // Returns list of pending/failed downloads
        console.log("Queued downloads:", records);
    },
    (err) => console.error(err)
);
```

### 3. Fetch Completed Downloads (Access JSON Results)

The success callback receives an object shaped as `{ records: [...], hasMore: boolean }` — **not** a plain array. `records` is the list of completed items; `hasMore` is only meaningful when you pass `limit`/`offset`.

```javascript
syncEngine.getCompletedDownloads(
    (response) => {
        // response = { records: [...], hasMore: false }
        response.records.forEach(item => {
            if (item.downloadStrategy === 'REST_PAYLOAD') {
                const data = JSON.parse(item.responseData);
                console.log("Downloaded Metadata Payload:", data);
            } else {
                console.log("Downloaded Binary File located at:", item.filePath);
            }
        });
    },
    (err) => console.error(err)
);
```

Optionally pass `{ limit, offset }` as the first argument to paginate through large result sets, avoiding loading everything into memory at once.

**If `autoDeleteCompleted` is `false`** (records stay in the queue until you call `removeDownloads`), `offset` behaves like normal pagination — increment it page over page:

```javascript
async function fetchAllPages() {
    let offset = 0;
    const pageSize = 50;
    let hasMore = true;
    while (hasMore) {
        const response = await new Promise((resolve, reject) => {
            syncEngine.getCompletedDownloads({ limit: pageSize, offset }, resolve, reject);
        });
        // ...process response.records...
        hasMore = response.hasMore;
        offset += pageSize;
    }
}
```

**If `autoDeleteCompleted` is `true`**, each page is deleted from the queue as soon as it's read — so the next page is always at `offset: 0` relative to what's left, never an incrementing offset. The plugin enforces this internally (any `offset` you pass is ignored when `autoDeleteCompleted` is `true`), but the correct client-side loop keeps requesting `offset: 0` until `hasMore` is `false`:

```javascript
async function drainAllPages() {
    const pageSize = 50;
    let hasMore = true;
    while (hasMore) {
        const response = await new Promise((resolve, reject) => {
            syncEngine.getCompletedDownloads({ limit: pageSize, offset: 0 }, resolve, reject);
        });
        // ...process response.records, which have already been deleted from the queue...
        hasMore = response.hasMore;
    }
}
```

### 4. Remove Downloads

```javascript
syncEngine.removeDownloads(
    ["delta_metadata_1"],
    (success) => console.log("Downloads deleted from queue database."),
    (err) => console.error(err)
);
```

### 5. Clear Download Queue

```javascript
syncEngine.clearDownloadQueue(
    (success) => console.log("Download queue purged."),
    (err) => console.error(err)
);
```

---

---

## File Path Resolution & Sandboxing

Writing to arbitrary system directories will trigger OS security and permission exceptions. The background engine requires a **fully qualified absolute native file path** (starting with `file://` or `/`) to successfully write data out-of-process.

While the plugin tries to resolve `cdvfile://` URIs natively using `webView.resourceApi.mapUriToFile` on both Android and iOS, this lookup may return null if the Cordova File plugin is not fully loaded during the database write.

### Recommended Integration Plan (Pre-Resolving Paths in JS)

To ensure maximum reliability and compatibility with both **Cordova** and **Capacitor** environments, resolve `cdvfile://` URIs to native absolute file paths in JavaScript *before* calling `enqueueDownload` using the following unified helper:

```javascript
/**
 * Unified helper to resolve cdvfile:// URIs to native file:// URLs
 * Supports both Capacitor (Filesystem plugin) and Cordova (File plugin) environments.
 */
async function resolveToNativePath(filePath) {
  if (!filePath) return filePath;

  // 1. If it's already a native absolute file path, return it as-is
  if (filePath.startsWith('file://') || filePath.startsWith('/')) {
    return filePath;
  }

  // 2. Try Capacitor Filesystem resolution if available
  const isCapacitor = window.Capacitor && window.Capacitor.Plugins && window.Capacitor.Plugins.Filesystem;
  if (isCapacitor && filePath.startsWith('cdvfile://')) {
    try {
      const Filesystem = window.Capacitor.Plugins.Filesystem;
      let directory = null;
      let relativePath = '';

      if (filePath.startsWith('cdvfile://localhost/temporary/')) {
        relativePath = filePath.substring('cdvfile://localhost/temporary/'.length);
        directory = 'CACHE'; // Capacitor Cache directory
      } else if (filePath.startsWith('cdvfile://localhost/persistent/')) {
        relativePath = filePath.substring('cdvfile://localhost/persistent/'.length);
        directory = 'DOCUMENTS'; // Capacitor Documents directory
      }

      if (directory) {
        const result = await Filesystem.getUri({
          directory: directory,
          path: relativePath
        });
        return result.uri;
      }
    } catch (err) {
      console.warn('Capacitor Filesystem resolution failed, falling back to Cordova:', err);
    }
  }

  // 3. Try Cordova File resolution
  if (filePath.startsWith('cdvfile://')) {
    // Attempt fast synchronous mapping via cordova.file globals
    let mapped = null;
    if (filePath.startsWith('cdvfile://localhost/temporary/')) {
      const relative = filePath.substring('cdvfile://localhost/temporary/'.length);
      const base = window.cordova?.file?.tempDirectory || window.cordova?.file?.cacheDirectory;
      if (base) mapped = base + relative;
    } else if (filePath.startsWith('cdvfile://localhost/persistent/')) {
      const relative = filePath.substring('cdvfile://localhost/persistent/'.length);
      const base = window.cordova?.file?.dataDirectory;
      if (base) mapped = base + relative;
    }
    if (mapped) return mapped;

    // Async fallback using resolveLocalFileSystemURL
    if (window.resolveLocalFileSystemURL) {
      return new Promise((resolve, reject) => {
        window.resolveLocalFileSystemURL(filePath, (entry) => {
          resolve(entry.nativeURL || entry.toURL());
        }, (err) => {
          reject(new Error(`Cordova resolveLocalFileSystemURL failed: ${JSON.stringify(err)}`));
        });
      });
    }
  }

  return filePath;
}
```

---

## Opening Downloaded Files Natively

In modern Capacitor WebViews, opening local file system URLs (`file://` or `_capacitor_file_`) using `window.open(path, '_blank')` will fail or trigger single-page app routing errors (e.g. attempting to fetch `/favicon.svg`) due to CORS and security policies.

To open downloaded files (such as PDFs, photos, or documents) in the device's system viewer, integrate `cordova-plugin-file` and `cordova-plugin-file-opener2` into your application:

### Implementation Steps

1. Install the required plugins in the app:

   ```bash
   npm install cordova-plugin-file cordova-plugin-file-opener2
   npx cap sync
   ```

2. Add a helper to open files using `fileOpener2` in your JavaScript/TypeScript code:

```javascript
const getMimeType = (path) => {
  const ext = path.split('.').pop().toLowerCase();
  const map = {
    'pdf': 'application/pdf',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'txt': 'text/plain',
    'mp4': 'video/mp4',
    'mov': 'video/quicktime',
    'zip': 'application/zip',
    'doc': 'application/msword',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
  };
  return map[ext] || '*/*';
};

const handleOpenFile = (filePath) => {
  if (!filePath) return;
  try {
    const fileOpener = window.cordova?.plugins?.fileOpener2;
    if (!fileOpener) {
      console.error('cordova-plugin-file-opener2 is not available.');
      return;
    }
    
    // Ensure target path has the file:// scheme
    let targetPath = filePath;
    if (!targetPath.startsWith('file://')) {
      targetPath = 'file://' + targetPath;
    }
    
    const mimeType = getMimeType(targetPath);
    console.log(`Opening file natively: ${targetPath} (${mimeType})`);
    
    fileOpener.open(
      targetPath,
      mimeType,
      {
        error: (err) => {
          console.error(`fileOpener2 Error: [${err.status}] ${err.message}`);
          // Fallback to show open dialog options
          fileOpener.showOpenWithDialog(targetPath, mimeType, {
            error: (e) => console.error(`fileOpener2 Dialog Error: ${e.message}`),
            success: () => console.log('Opened file chooser options dialog.')
          });
        },
        success: () => {
          console.log('File opened successfully.');
        }
      }
    );
  } catch (err) {
    console.error(`Failed to open file: ${err.message}`);
  }
};
```

---

## Server-Side REST Endpoint Configuration

When defining download endpoints in your OutSystems backend, configure them depending on the strategy:

### 1. Binary File Download Strategy (`BINARY_FILE`)
This strategy is used to stream binary files (PDFs, images, videos) directly to the local storage.
* **HTTP Method**: **`GET`** (Required: the native iOS/Android engine executes a GET request for streaming binaries).
* **OutSystems API Configuration**:
  - Add an **Output Parameter** (e.g. `FileContent`).
  - Set its **Data Type** to **`Binary Data`**.
  - Set **`Send In`** to **`Body`**. This ensures the server sends raw binary bytes instead of a JSON envelope.

### 2. JSON/Metadata Sync Strategy (`REST_PAYLOAD`)
This strategy retrieves lightweight JSON metadata responses to be stored in the database.
* **HTTP Method**: **`GET`** or **`POST`** (The engine executes `POST` if a `payload` body string is provided; otherwise, it executes `GET`).
* **OutSystems API Configuration**:
  - Set the output structure/parameter to return a standard JSON object or list.

---

## OutSystems Mobile Integration Plan

In OutSystems, JavaScript blocks inside Client Actions execute in the context of the mobile application. You can wrap the path resolution and file opening code into reusable OutSystems **Client Actions**, or leverage the official **File Plugin** to get native paths directly.

### 1. Retrieving Native Paths via OutSystems File Plugin (Recommended)

Instead of using virtual `cdvfile://` URIs, you can use the official **File Plugin** from the OutSystems Forge to obtain native file paths starting with `file://` directly:

- **Persistent storage**: Use `Directory.DataDirectoryPath` (e.g., `Directory.DataDirectoryPath + "attachments/photo_456.jpg"`).
- **Temporary/Cache storage**: Use `Directory.CacheDirectoryPath` (e.g., `Directory.CacheDirectoryPath + "temp/photo_456.jpg"`).

Paths obtained this way are fully absolute and can be passed directly to `enqueueDownload`'s `filePath` without any further resolution.

### 2. Extensibility Configurations (OutSystems Component)

Reference the plugin's Git repository in your OutSystems module's **Extensibility Configurations**:

```json
{
    "plugin": {
        "url": "https://github.com/henriquefps/cordova-background-sync-plugin.git"
    }
}
```
